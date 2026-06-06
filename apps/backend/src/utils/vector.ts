export function normalizeVector(values: number[], dimensions = values.length): number[] {
  const sized = values.slice(0, dimensions);
  while (sized.length < dimensions) sized.push(0);
  const norm = Math.sqrt(sized.reduce((sum, value) => sum + value * value, 0));
  if (!norm) return sized;
  return sized.map((value) => value / norm);
}

export function cosineSimilarity(a?: number[] | string | null, b?: number[] | string | null): number | null {
  const left = parseVector(a);
  const right = parseVector(b);
  if (!left || !right || left.length !== right.length) return null;
  let dot = 0;
  let leftNorm = 0;
  let rightNorm = 0;
  for (let i = 0; i < left.length; i += 1) {
    dot += left[i] * right[i];
    leftNorm += left[i] * left[i];
    rightNorm += right[i] * right[i];
  }
  if (!leftNorm || !rightNorm) return null;
  return dot / (Math.sqrt(leftNorm) * Math.sqrt(rightNorm));
}

export function parseVector(value?: number[] | string | null): number[] | null {
  if (!value) return null;
  if (Array.isArray(value)) return value;
  const trimmed = value.trim();
  if (!trimmed) return null;
  return trimmed
    .replace(/^\[/, '')
    .replace(/\]$/, '')
    .split(',')
    .map((part) => Number(part.trim()))
    .filter((part) => Number.isFinite(part));
}

export function vectorLiteral(values?: number[] | null): string | null {
  if (!values) return null;
  return `[${values.map((value) => Number(value.toFixed(8))).join(',')}]`;
}
