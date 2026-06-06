create extension if not exists vector with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create table public.rewind_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  device_id text not null,
  status text not null default 'pending'
    constraint rewind_events_status_check check (status in ('pending', 'committed', 'failed')),
  title text not null constraint rewind_events_title_nonempty check (length(trim(title)) > 0),
  description text not null constraint rewind_events_description_nonempty check (length(trim(description)) > 0),
  reason text,
  entities text[] not null default '{}',
  location_hint text,
  latitude double precision constraint rewind_events_latitude_check check (latitude is null or latitude between -90 and 90),
  longitude double precision constraint rewind_events_longitude_check check (longitude is null or longitude between -180 and 180),
  started_at timestamptz,
  ended_at timestamptz,
  local_asset_id text,
  thumbnail_frame_uuid uuid,
  embedding extensions.vector(768),
  search_tsv tsvector not null default ''::tsvector,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint rewind_events_time_range_check check (started_at is null or ended_at is null or ended_at >= started_at)
);

create table public.rewind_frames (
  id uuid primary key default gen_random_uuid(),
  rewind_event_id uuid not null references public.rewind_events(id) on delete cascade,
  user_id uuid not null,
  device_id text not null,
  device_frame_uuid uuid not null,
  local_asset_id text,
  order_index integer not null constraint rewind_frames_order_index_check check (order_index >= 0),
  captured_at timestamptz,
  offset_ms integer constraint rewind_frames_offset_ms_check check (offset_ms is null or offset_ms >= 0),
  caption text,
  embedding extensions.vector(768),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (rewind_event_id, device_frame_uuid)
);

create function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create function public.update_rewind_event_search_tsv()
returns trigger
language plpgsql
as $$
begin
  new.search_tsv :=
    setweight(to_tsvector('simple', coalesce(new.title, '')), 'A') ||
    setweight(to_tsvector('simple', coalesce(array_to_string(new.entities, ' '), '')), 'A') ||
    setweight(to_tsvector('simple', coalesce(new.description, '')), 'B') ||
    setweight(to_tsvector('simple', coalesce(new.location_hint, '')), 'C');
  return new;
end;
$$;

create trigger rewind_events_set_updated_at
before update on public.rewind_events
for each row execute function public.set_updated_at();

create trigger rewind_events_update_search_tsv
before insert or update of title, description, entities, location_hint
on public.rewind_events
for each row execute function public.update_rewind_event_search_tsv();

create index rewind_events_embedding_hnsw_idx
  on public.rewind_events using hnsw (embedding extensions.vector_cosine_ops)
  with (m = 16, ef_construction = 64)
  where embedding is not null;

create index rewind_frames_embedding_hnsw_idx
  on public.rewind_frames using hnsw (embedding extensions.vector_cosine_ops)
  with (m = 16, ef_construction = 64)
  where embedding is not null;

create index rewind_events_search_tsv_idx
  on public.rewind_events using gin (search_tsv);

create index rewind_events_entities_idx
  on public.rewind_events using gin (entities);

create index rewind_events_user_created_idx
  on public.rewind_events (user_id, created_at desc);

create index rewind_events_user_status_created_idx
  on public.rewind_events (user_id, status, created_at desc);

create index rewind_events_user_device_created_idx
  on public.rewind_events (user_id, device_id, created_at desc);

create index rewind_events_user_started_idx
  on public.rewind_events (user_id, started_at desc)
  where started_at is not null;

create index rewind_events_user_ended_idx
  on public.rewind_events (user_id, ended_at desc)
  where ended_at is not null;

create index rewind_frames_event_order_idx
  on public.rewind_frames (rewind_event_id, order_index);

create index rewind_frames_event_embedding_idx
  on public.rewind_frames (rewind_event_id)
  where embedding is not null;

create index rewind_frames_user_captured_idx
  on public.rewind_frames (user_id, captured_at desc)
  where captured_at is not null;

create index rewind_frames_device_frame_uuid_idx
  on public.rewind_frames (device_id, device_frame_uuid);

create function public.match_rewind_events(
  p_user_id uuid,
  p_query_text text default null,
  p_query_embedding extensions.vector(768) default null,
  p_entities text[] default null,
  p_location_hint text default null,
  p_statuses text[] default null,
  p_started_after timestamptz default null,
  p_ended_before timestamptz default null,
  p_limit integer default 10
)
returns table (
  id uuid,
  user_id uuid,
  device_id text,
  status text,
  title text,
  description text,
  reason text,
  entities text[],
  location_hint text,
  latitude double precision,
  longitude double precision,
  started_at timestamptz,
  ended_at timestamptz,
  local_asset_id text,
  thumbnail_frame_uuid uuid,
  metadata jsonb,
  created_at timestamptz,
  updated_at timestamptz,
  similarity double precision,
  event_similarity double precision,
  frame_similarity double precision,
  text_rank double precision
)
language plpgsql
stable
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 10), 50));
  v_candidate_limit integer := greatest(50, least(greatest(1, coalesce(p_limit, 10)) * 20, 400));
begin
  perform set_config('hnsw.ef_search', '100', true);
  perform set_config('hnsw.iterative_scan', 'strict_order', true);

  return query
  with query_terms as (
    select
      nullif(trim(coalesce(p_query_text, '')), '') as query_text,
      nullif(trim(coalesce(p_location_hint, '')), '') as location_text,
      case
        when nullif(trim(coalesce(p_query_text, '')), '') is null then null
        else websearch_to_tsquery('simple', p_query_text)
      end as ts_query
  ),
  event_vector_candidates as (
    select
      e.id,
      (1 - (e.embedding operator(extensions.<=>) p_query_embedding))::double precision as event_similarity
    from public.rewind_events e
    cross join query_terms q
    where p_query_embedding is not null
      and e.embedding is not null
      and e.user_id = p_user_id
      and case
        when p_statuses is null or array_length(p_statuses, 1) is null then e.status in ('committed', 'pending')
        else e.status = any(p_statuses)
      end
      and (p_entities is null or array_length(p_entities, 1) is null or e.entities && p_entities)
      and (q.location_text is null or e.location_hint ilike '%' || q.location_text || '%')
      and (p_started_after is null or coalesce(e.ended_at, e.started_at, e.created_at) >= p_started_after)
      and (p_ended_before is null or coalesce(e.started_at, e.ended_at, e.created_at) <= p_ended_before)
    order by e.embedding operator(extensions.<=>) p_query_embedding
    limit v_candidate_limit
  ),
  frame_vector_candidates as (
    select
      ranked.rewind_event_id as id,
      max(ranked.frame_similarity)::double precision as frame_similarity
    from (
      select
        f.rewind_event_id,
        (1 - (f.embedding operator(extensions.<=>) p_query_embedding))::double precision as frame_similarity
      from public.rewind_frames f
      join public.rewind_events e on e.id = f.rewind_event_id
      cross join query_terms q
      where p_query_embedding is not null
        and f.embedding is not null
        and e.user_id = p_user_id
        and case
          when p_statuses is null or array_length(p_statuses, 1) is null then e.status in ('committed', 'pending')
          else e.status = any(p_statuses)
        end
        and (p_entities is null or array_length(p_entities, 1) is null or e.entities && p_entities)
        and (q.location_text is null or e.location_hint ilike '%' || q.location_text || '%')
        and (p_started_after is null or coalesce(e.ended_at, e.started_at, e.created_at) >= p_started_after)
        and (p_ended_before is null or coalesce(e.started_at, e.ended_at, e.created_at) <= p_ended_before)
      order by f.embedding operator(extensions.<=>) p_query_embedding
      limit v_candidate_limit
    ) ranked
    group by ranked.rewind_event_id
  ),
  text_candidates as (
    select
      e.id,
      ts_rank_cd(e.search_tsv, q.ts_query)::double precision as text_rank
    from public.rewind_events e
    cross join query_terms q
    where q.ts_query is not null
      and e.user_id = p_user_id
      and case
        when p_statuses is null or array_length(p_statuses, 1) is null then e.status in ('committed', 'pending')
        else e.status = any(p_statuses)
      end
      and e.search_tsv @@ q.ts_query
      and (p_entities is null or array_length(p_entities, 1) is null or e.entities && p_entities)
      and (q.location_text is null or e.location_hint ilike '%' || q.location_text || '%')
      and (p_started_after is null or coalesce(e.ended_at, e.started_at, e.created_at) >= p_started_after)
      and (p_ended_before is null or coalesce(e.started_at, e.ended_at, e.created_at) <= p_ended_before)
    order by ts_rank_cd(e.search_tsv, q.ts_query) desc
    limit v_candidate_limit
  ),
  recent_candidates as (
    select e.id
    from public.rewind_events e
    cross join query_terms q
    where p_query_embedding is null
      and q.ts_query is null
      and e.user_id = p_user_id
      and case
        when p_statuses is null or array_length(p_statuses, 1) is null then e.status in ('committed', 'pending')
        else e.status = any(p_statuses)
      end
      and (p_entities is null or array_length(p_entities, 1) is null or e.entities && p_entities)
      and (q.location_text is null or e.location_hint ilike '%' || q.location_text || '%')
      and (p_started_after is null or coalesce(e.ended_at, e.started_at, e.created_at) >= p_started_after)
      and (p_ended_before is null or coalesce(e.started_at, e.ended_at, e.created_at) <= p_ended_before)
    order by e.created_at desc
    limit v_candidate_limit
  ),
  candidate_ids as (
    select evc.id from event_vector_candidates evc
    union
    select fvc.id from frame_vector_candidates fvc
    union
    select tc.id from text_candidates tc
    union
    select rc.id from recent_candidates rc
  ),
  scores as (
    select
      c.id,
      ev.event_similarity,
      fv.frame_similarity,
      tc.text_rank,
      greatest(coalesce(ev.event_similarity, -1), coalesce(fv.frame_similarity, -1))::double precision as vector_similarity
    from candidate_ids c
    left join event_vector_candidates ev on ev.id = c.id
    left join frame_vector_candidates fv on fv.id = c.id
    left join text_candidates tc on tc.id = c.id
  )
  select
    e.id,
    e.user_id,
    e.device_id,
    e.status,
    e.title,
    e.description,
    e.reason,
    e.entities,
    e.location_hint,
    e.latitude,
    e.longitude,
    e.started_at,
    e.ended_at,
    e.local_asset_id,
    e.thumbnail_frame_uuid,
    e.metadata,
    e.created_at,
    e.updated_at,
    case when s.vector_similarity < 0 then null else s.vector_similarity end as similarity,
    s.event_similarity,
    s.frame_similarity,
    coalesce(s.text_rank, 0)::double precision as text_rank
  from scores s
  join public.rewind_events e on e.id = s.id
  order by
    (greatest(coalesce(s.vector_similarity, 0), 0) * 0.70 + coalesce(s.text_rank, 0) * 0.30) desc,
    e.created_at desc
  limit v_limit;
end;
$$;
