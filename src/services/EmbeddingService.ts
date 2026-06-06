import { createHash } from 'node:crypto';
import { GoogleGenAI, createPartFromBase64 } from '@google/genai';
import { config } from '../config.js';
import type { JsonObject } from '../types.js';
import { normalizeVector } from '../utils/vector.js';

const FRAME_EMBEDDING_MAX_PER_REWIND = 12;
const EMBEDDING_CACHE_SIZE = 512;
const FRAME_DESCRIPTION_CACHE_SIZE = 256;
const FRAME_SUMMARY_SYSTEM_INSTRUCTION =
  'Describe phone camera frames for semantic retrieval. Return one compact sentence with concrete objects, places, visible text, actions, and spatial hints. Do not add speculation.';

export class EmbeddingService {
  private readonly ai: GoogleGenAI;
  private readonly embeddingCache = new LruCache<string, Promise<number[]>>(EMBEDDING_CACHE_SIZE);
  private readonly frameDescriptionCache = new LruCache<string, Promise<string>>(FRAME_DESCRIPTION_CACHE_SIZE);

  constructor() {
    if (!config.MODEL_API_KEY) {
      throw new Error('MODEL_API_KEY is required.');
    }
    this.ai = new GoogleGenAI({ apiKey: config.MODEL_API_KEY });
  }

  async embedDocument(text: string): Promise<number[]> {
    return this.embedText(text, 'RETRIEVAL_DOCUMENT', config.TEXT_EMBEDDING_MODEL);
  }

  async embedQuery(text: string): Promise<number[]> {
    return this.embedText(text, 'RETRIEVAL_QUERY', config.TEXT_EMBEDDING_MODEL);
  }

  async embedText(text: string, taskType = 'SEMANTIC_SIMILARITY', model = config.TEXT_EMBEDDING_MODEL): Promise<number[]> {
    const normalizedText = text.trim();
    const content = prepareEmbeddingText(normalizedText, taskType, model);
    const cacheKey = [
      'text',
      model,
      config.EMBEDDING_DIMENSION,
      taskType,
      hashText(content)
    ].join(':');
    const cached = this.embeddingCache.get(cacheKey);
    if (cached) return cached;

    const pending = this.ai.models
      .embedContent({
        model,
        contents: content,
        config: embeddingConfig(taskType, model)
      })
      .then((response) => {
        const values = response.embeddings?.[0]?.values;
        if (!values?.length) {
          throw new Error('Gemini text embedding response did not include values.');
        }
        return normalizeVector(values, config.EMBEDDING_DIMENSION);
      })
      .catch((error) => {
        this.embeddingCache.delete(cacheKey);
        throw error;
      });
    this.embeddingCache.set(cacheKey, pending);
    return pending;
  }

  async embedImage(input: { base64: string; mimeType: string; textHint?: string }): Promise<number[]> {
    const result = await this.embedFrameImage(input);
    return result.embedding;
  }

  async embedFrameImage(input: { base64: string; mimeType: string; textHint?: string }): Promise<{ embedding: number[]; description: string }> {
    if (isEmbeddingModel(config.IMAGE_EMBEDDING_MODEL)) {
      const description = input.textHint?.trim() || 'Phone camera frame from a rewind memory.';
      const embedding = await this.embedMultimodalFrame(input, description);
      return { embedding, description };
    }
    const description = await this.describeFrame(input);
    const embedding = await this.embedDocument(description);
    return { embedding, description };
  }

  private async embedMultimodalFrame(input: { base64: string; mimeType: string; textHint?: string }, description: string): Promise<number[]> {
    const textHint = input.textHint?.trim() ?? '';
    const cacheKey = [
      'image',
      config.IMAGE_EMBEDDING_MODEL,
      config.EMBEDDING_DIMENSION,
      input.mimeType,
      hashText(textHint),
      hashText(input.base64)
    ].join(':');
    const cached = this.embeddingCache.get(cacheKey);
    if (cached) return cached;

    const pending = this.ai.models
      .embedContent({
        model: config.IMAGE_EMBEDDING_MODEL,
        contents: [
          createPartFromBase64(input.base64, input.mimeType),
          prepareEmbeddingText(description, 'RETRIEVAL_DOCUMENT', config.IMAGE_EMBEDDING_MODEL)
        ],
        config: embeddingConfig('RETRIEVAL_DOCUMENT', config.IMAGE_EMBEDDING_MODEL)
      })
      .then((response) => {
        const values = response.embeddings?.[0]?.values;
        if (!values?.length) {
          throw new Error('Gemini frame embedding response did not include values.');
        }
        return normalizeVector(values, config.EMBEDDING_DIMENSION);
      })
      .catch((error) => {
        this.embeddingCache.delete(cacheKey);
        throw error;
      });
    this.embeddingCache.set(cacheKey, pending);
    return pending;
  }

  async describeFrame(input: { base64: string; mimeType: string; textHint?: string }): Promise<string> {
    const textHint = input.textHint?.trim() ?? '';
    const cacheKey = ['frame', config.IMAGE_EMBEDDING_MODEL, input.mimeType, hashText(textHint), hashText(input.base64)].join(':');
    const cached = this.frameDescriptionCache.get(cacheKey);
    if (cached) return cached;

    const pending = this.ai.models
      .generateContent({
        model: config.IMAGE_EMBEDDING_MODEL,
        contents: [
          createPartFromBase64(input.base64, input.mimeType),
          textHint ? `Known local frame caption: ${textHint}\nWrite the retrieval description.` : 'Write the retrieval description.'
        ],
        config: {
          systemInstruction: FRAME_SUMMARY_SYSTEM_INSTRUCTION,
          temperature: 0,
          maxOutputTokens: 96,
          responseMimeType: 'text/plain'
        }
      })
      .then((response) => {
        const text = response.text?.trim();
        if (!text) {
          throw new Error('Gemini image description response did not include text.');
        }
        return text;
      })
      .catch((error) => {
        this.frameDescriptionCache.delete(cacheKey);
        throw error;
      });
    this.frameDescriptionCache.set(cacheKey, pending);
    return pending;
  }

  shouldEmbedFrameImages(): boolean {
    return config.EMBEDDING_MODE === 'text_and_image' && FRAME_EMBEDDING_MAX_PER_REWIND > 0;
  }

  frameEmbeddingLimit(): number {
    return FRAME_EMBEDDING_MAX_PER_REWIND;
  }

  buildEventEmbeddingText(input: {
    title?: string;
    description?: string;
    entities?: string[];
    location_hint?: string | null;
    frame_captions?: string[];
    metadata?: JsonObject;
  }): string {
    const parts = [
      input.title,
      input.description,
      input.entities?.length ? `Entities: ${input.entities.join(', ')}` : undefined,
      input.location_hint ? `Location: ${input.location_hint}` : undefined,
      input.frame_captions?.length ? `Frame captions: ${input.frame_captions.join(' | ')}` : undefined,
      input.metadata ? `Metadata: ${JSON.stringify(input.metadata)}` : undefined
    ];
    return parts.filter(Boolean).join('\n');
  }
}

function hashText(value: string): string {
  return createHash('sha256').update(value).digest('base64url');
}

function isEmbeddingModel(model: string): boolean {
  return model.includes('embedding');
}

function isEmbedding2(model: string): boolean {
  return model.includes('embedding-2');
}

function prepareEmbeddingText(text: string, taskType: string, model: string): string {
  if (!isEmbedding2(model)) return text;
  if (taskType === 'RETRIEVAL_QUERY') return `task: search result | query: ${text}`;
  if (taskType === 'RETRIEVAL_DOCUMENT') return `title: rewind memory | text: ${text}`;
  return text;
}

function embeddingConfig(taskType: string, model: string) {
  return isEmbedding2(model)
    ? { outputDimensionality: config.EMBEDDING_DIMENSION }
    : { taskType, outputDimensionality: config.EMBEDDING_DIMENSION };
}

class LruCache<K, V> {
  private readonly values = new Map<K, V>();

  constructor(private readonly maxSize: number) {}

  get(key: K): V | undefined {
    const value = this.values.get(key);
    if (value === undefined) return undefined;
    this.values.delete(key);
    this.values.set(key, value);
    return value;
  }

  set(key: K, value: V): void {
    if (this.values.has(key)) this.values.delete(key);
    this.values.set(key, value);
    while (this.values.size > this.maxSize) {
      const oldest = this.values.keys().next().value;
      if (oldest === undefined) break;
      this.values.delete(oldest);
    }
  }

  delete(key: K): void {
    this.values.delete(key);
  }
}
