import { config as loadDotenv } from 'dotenv';
import { readFileSync } from 'node:fs';
import { z } from 'zod';

loadDotenv({ path: '.env.backend', override: true });

const emptyToUndefined = (value: unknown) => (typeof value === 'string' && value.trim() === '' ? undefined : value);

const ModelDefaults = {
  EMBEDDING_PROVIDER: 'gemini',
  TEXT_EMBEDDING_MODEL: 'gemini-embedding-2',
  IMAGE_EMBEDDING_MODEL: 'gemini-embedding-2',
  EMBEDDING_DIMENSION: 768
} as const;

const EnvSchema = z.object({
  PORT: z.coerce.number().default(8787),
  HOST: z.string().default('0.0.0.0'),
  DEV_USER_ID: z.uuid().default('00000000-0000-4000-8000-000000000001'),
  DEV_DEVICE_ID: z.string().default('dev-phone'),
  SUPABASE_URL: z.preprocess(emptyToUndefined, z.string().url().optional()),
  SUPABASE_SERVICE_ROLE_KEY: z.preprocess(emptyToUndefined, z.string().optional()),
  MODEL_API_KEY: z.preprocess(emptyToUndefined, z.string().optional()),
  EMBEDDING_MODE: z.enum(['text_only', 'text_and_image']).default('text_only'),
  TEXT_EMBEDDING_MODEL: z.preprocess(emptyToUndefined, z.string().optional()).default(ModelDefaults.TEXT_EMBEDDING_MODEL),
  IMAGE_EMBEDDING_MODEL: z.preprocess(emptyToUndefined, z.string().optional()).default(ModelDefaults.IMAGE_EMBEDDING_MODEL),
  LIVE_MODEL_NAME: z.string().default('gemini-2.5-flash-native-audio-preview-12-2025'),
  DEV_HTTPS: envBool(false),
  TLS_CERT_PATH: z.string().optional(),
  TLS_KEY_PATH: z.string().optional()
});

const parsed = EnvSchema.parse(process.env);

export const config = {
  ...ModelDefaults,
  ...parsed,
  repositoryMode: parsed.SUPABASE_URL?.includes('127.0.0.1') || parsed.SUPABASE_URL?.includes('host.docker.internal') ? 'supabase-local' : 'supabase-remote',
  httpsOptions:
    parsed.DEV_HTTPS && parsed.TLS_CERT_PATH && parsed.TLS_KEY_PATH
      ? {
          cert: readFileSync(parsed.TLS_CERT_PATH),
          key: readFileSync(parsed.TLS_KEY_PATH)
        }
      : undefined
};

function envBool(defaultValue: boolean) {
  return z
    .preprocess((value) => {
      if (value === undefined || value === '') return undefined;
      if (typeof value === 'boolean') return value;
      if (typeof value === 'string') return ['1', 'true', 'yes', 'on'].includes(value.toLowerCase());
      return value;
    }, z.boolean())
    .default(defaultValue);
}
