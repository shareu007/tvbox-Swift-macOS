/// Incremental newline parser that rejects an oversized line before buffering it.
export function attachBoundedLineReader(stream, options) {
  const maximumBytes = Math.max(1, options.maximumBytes);
  let chunks = [];
  let total = 0;
  let closed = false;

  const reset = () => {
    chunks = [];
    total = 0;
  };
  const detach = () => {
    stream.off("data", onData);
    stream.off("end", onEnd);
    stream.off("error", onError);
  };
  const failTooLarge = () => {
    if (closed) return;
    closed = true;
    detach();
    reset();
    options.onOverflow();
  };
  const emit = () => {
    let line = Buffer.concat(chunks, total);
    if (line.at(-1) === 0x0d) line = line.subarray(0, -1);
    reset();
    options.onLine(line.toString("utf8"));
  };
  const append = (chunk) => {
    if (chunk.length === 0) return true;
    if (total + chunk.length > maximumBytes) {
      failTooLarge();
      return false;
    }
    chunks.push(chunk);
    total += chunk.length;
    return true;
  };
  const onData = (value) => {
    if (closed) return;
    const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
    let offset = 0;
    while (offset <= chunk.length) {
      const newline = chunk.indexOf(0x0a, offset);
      if (newline === -1) {
        append(chunk.subarray(offset));
        return;
      }
      if (!append(chunk.subarray(offset, newline))) return;
      emit();
      offset = newline + 1;
      if (offset === chunk.length) return;
    }
  };
  const onEnd = () => {
    if (closed) return;
    closed = true;
    detach();
    if (total > 0) emit();
  };
  const onError = (error) => {
    if (closed) return;
    closed = true;
    detach();
    reset();
    options.onError?.(error);
  };

  stream.on("data", onData);
  stream.once("end", onEnd);
  stream.once("error", onError);
  return {
    close() {
      if (closed) return;
      closed = true;
      detach();
      reset();
    }
  };
}
