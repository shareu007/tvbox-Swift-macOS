export const MAXIMUM_SECURE_CONFIG_BYTES = 64 * 1024;

export function parseBoundedJSONObject(
  value,
  maximumBytes = MAXIMUM_SECURE_CONFIG_BYTES,
  label = "Secure configuration"
) {
  const buffer = Buffer.isBuffer(value) ? value : Buffer.from(String(value || ""));
  if (buffer.length === 0) return {};
  if (buffer.length > maximumBytes) {
    throw new Error(`${label} exceeds the size limit`);
  }
  let parsed;
  try {
    parsed = JSON.parse(buffer.toString("utf8"));
  } catch {
    throw new Error(`${label} is not valid JSON`);
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`${label} must be a JSON object`);
  }
  return parsed;
}

export async function readBoundedJSONObject(
  stream,
  maximumBytes = MAXIMUM_SECURE_CONFIG_BYTES,
  label = "Secure configuration"
) {
  const chunks = [];
  let total = 0;
  for await (const chunk of stream) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    total += buffer.length;
    if (total > maximumBytes) {
      throw new Error(`${label} exceeds the size limit`);
    }
    chunks.push(buffer);
  }
  return parseBoundedJSONObject(Buffer.concat(chunks), maximumBytes, label);
}

export function serializeBoundedJSONObject(
  value,
  maximumBytes = MAXIMUM_SECURE_CONFIG_BYTES,
  label = "Secure configuration"
) {
  let serialized;
  try {
    serialized = JSON.stringify(value || {});
  } catch {
    throw new Error(`${label} cannot be serialized`);
  }
  if (Buffer.byteLength(serialized) > maximumBytes) {
    throw new Error(`${label} exceeds the size limit`);
  }
  return serialized;
}
