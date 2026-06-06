(function () {
  const DEFAULT_FRAME_COUNT_BEFORE_AND_AFTER = 10;

  function deviceFrameImageUrl(deviceFrameUuid) {
    return `/device/frames/${encodeURIComponent(deviceFrameUuid)}/image`;
  }

  function frameTimeMs(frame, fallbackIndex = 0) {
    const captured = Date.parse(frame.captured_at || frame.capturedAt || '');
    if (Number.isFinite(captured)) return captured;
    const offset = Number(frame.offset_ms ?? frame.offsetMs);
    if (Number.isFinite(offset)) return offset;
    return fallbackIndex;
  }

  function normalizeFrameRef(ref, options = {}) {
    const frameUuid = ref.device_frame_uuid || ref.deviceFrameUuid || ref.uuid || ref.id;
    const asset = frameUuid && options.assetResolver ? options.assetResolver(frameUuid) : null;
    return {
      ...ref,
      device_frame_uuid: frameUuid,
      captured_at: ref.captured_at || ref.capturedAt || null,
      offset_ms: ref.offset_ms ?? ref.offsetMs ?? null,
      src: asset?.dataUrl || asset?.src || ref.src || (frameUuid ? deviceFrameImageUrl(frameUuid) : '')
    };
  }

  function compileFrameRefs(frameRefs, options = {}) {
    return [...(frameRefs || [])]
      .sort((a, b) => frameTimeMs(a) - frameTimeMs(b))
      .map((ref) => normalizeFrameRef(ref, options))
      .filter((ref) => ref.src);
  }

  function resultReferenceDate(result) {
    const startedAt = parseDate(result?.started_at || result?.startedAt);
    const endedAt = parseDate(result?.ended_at || result?.endedAt);

    if (startedAt && endedAt) {
      return new Date(startedAt.getTime() + (endedAt.getTime() - startedAt.getTime()) / 2);
    }

    return startedAt || endedAt || null;
  }

  function resultImageMatchWindowSeconds(result) {
    const startedAt = parseDate(result?.started_at || result?.startedAt);
    const endedAt = parseDate(result?.ended_at || result?.endedAt);
    if (!startedAt || !endedAt) return 15;

    const eventDurationSeconds = Math.abs(endedAt.getTime() - startedAt.getTime()) / 1000;
    return Math.min(Math.max(eventDurationSeconds / 2 + 10, 15), 120);
  }

  async function fetchDeviceFrames(options = {}) {
    const fetchImpl = options.fetchImpl || window.fetch.bind(window);
    const response = await fetchImpl('/device/frames', { cache: 'no-store' });
    if (!response.ok) throw new Error(`Device frame store returned ${response.status}`);
    const payload = await response.json();
    return [...(payload.frames || [])].sort((a, b) => frameTimeMs(a) - frameTimeMs(b));
  }

  async function compileFrameWindow(result, options = {}) {
    const targetDate = resultReferenceDate(result);
    if (!targetDate) return [];

    const frames = options.deviceFrames || (await fetchDeviceFrames(options));
    if (!frames.length) return [];

    const maximumDistanceMs = resultImageMatchWindowSeconds(result) * 1000;
    let nearestFrameIndex = -1;
    let nearestDistanceMs = Number.POSITIVE_INFINITY;

    frames.forEach((frame, index) => {
      const capturedMs = frameTimeMs(frame, index);
      const distanceMs = Math.abs(capturedMs - targetDate.getTime());
      if (distanceMs < nearestDistanceMs) {
        nearestDistanceMs = distanceMs;
        nearestFrameIndex = index;
      }
    });

    if (nearestFrameIndex < 0 || nearestDistanceMs > maximumDistanceMs) return [];

    const frameCount = Number.isFinite(options.frameCountBeforeAndAfter)
      ? options.frameCountBeforeAndAfter
      : DEFAULT_FRAME_COUNT_BEFORE_AND_AFTER;
    const lowerBound = Math.max(0, nearestFrameIndex - frameCount);
    const upperBound = Math.min(frames.length - 1, nearestFrameIndex + frameCount);

    return frames.slice(lowerBound, upperBound + 1).map((frame) =>
      normalizeFrameRef(
        {
          device_frame_uuid: frame.device_frame_uuid,
          captured_at: frame.captured_at,
          offset_ms: frame.offset_ms
        },
        options
      )
    );
  }

  async function compileResultFrames(result, options = {}) {
    try {
      const localWindow = await compileFrameWindow(result, options);
      if (localWindow.length) return localWindow;
    } catch (error) {
      if (options.onError) options.onError(error);
    }

    return compileFrameRefs(result?.frame_refs || result?.frames || [], options);
  }

  function parseDate(value) {
    if (!value) return null;
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? null : date;
  }

  window.RewindFrameCache = {
    compileFrameRefs,
    compileFrameWindow,
    compileResultFrames,
    deviceFrameImageUrl,
    fetchDeviceFrames,
    normalizeFrameRef,
    resultImageMatchWindowSeconds,
    resultReferenceDate
  };
})();
