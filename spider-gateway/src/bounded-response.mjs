import { GatewayError } from "./errors.mjs";

export const DEFAULT_UPSTREAM_RESPONSE_BYTES = 4 * 1024 * 1024;

export async function readBoundedBuffer(response, options = {}) {
  const maximumBytes = options.maximumBytes || DEFAULT_UPSTREAM_RESPONSE_BYTES;
  const code = options.code || "UPSTREAM_RESPONSE_TOO_LARGE";
  const message = options.message || "Upstream response is too large";
  const declared = Number.parseInt(response.headers?.get?.("content-length") || "0", 10);
  if (declared > maximumBytes) {
    await response.body?.cancel?.().catch(() => {});
    throw new GatewayError(code, message, 413);
  }

  if (response.body?.[Symbol.asyncIterator]) {
    const chunks = [];
    let total = 0;
    for await (const value of response.body) {
      const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
      total += chunk.length;
      if (total > maximumBytes) {
        await response.body?.cancel?.().catch(() => {});
        throw new GatewayError(code, message, 413);
      }
      chunks.push(chunk);
    }
    return Buffer.concat(chunks, total);
  }

  // Lightweight test doubles may not expose a streaming body.
  if (typeof response.arrayBuffer === "function") {
    const buffer = Buffer.from(await response.arrayBuffer());
    if (buffer.length > maximumBytes) throw new GatewayError(code, message, 413);
    return buffer;
  }
  throw new GatewayError("INVALID_UPSTREAM_RESPONSE", "Upstream response body is unavailable", 502);
}

export async function readBoundedText(response, options = {}) {
  if (!response.body?.[Symbol.asyncIterator] && typeof response.text === "function") {
    const value = await response.text();
    if (Buffer.byteLength(value) > (options.maximumBytes || DEFAULT_UPSTREAM_RESPONSE_BYTES)) {
      throw new GatewayError(
        options.code || "UPSTREAM_RESPONSE_TOO_LARGE",
        options.message || "Upstream response is too large",
        413
      );
    }
    return value;
  }
  return (await readBoundedBuffer(response, options)).toString("utf8");
}

export async function readBoundedJSON(response, options = {}) {
  if (!response.body?.[Symbol.asyncIterator] && typeof response.json === "function") {
    const value = await response.json();
    if (Buffer.byteLength(JSON.stringify(value)) > (options.maximumBytes || DEFAULT_UPSTREAM_RESPONSE_BYTES)) {
      throw new GatewayError(
        options.code || "UPSTREAM_RESPONSE_TOO_LARGE",
        options.message || "Upstream response is too large",
        413
      );
    }
    return value;
  }
  const text = await readBoundedText(response, options);
  try {
    return JSON.parse(text);
  } catch {
    throw new GatewayError("INVALID_UPSTREAM_RESPONSE", "Upstream response contains invalid JSON", 502);
  }
}
