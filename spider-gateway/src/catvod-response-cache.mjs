const readActions = new Set(['home', 'category', 'search', 'detail']);

export function responseCacheKey(site, action, args) {
  if (!readActions.has(action)) return null;
  const values = Object.fromEntries(Object.entries(args).filter(([key]) => key !== 'verifyResource')
    .sort(([a], [b]) => a.localeCompare(b)));
  if (values.extend && typeof values.extend === 'object' && !Array.isArray(values.extend)) {
    values.extend = Object.fromEntries(Object.entries(values.extend).sort(([a], [b]) => a.localeCompare(b)));
  }
  return JSON.stringify([site.key, site.api, site.ext || '', action, values]);
}

function reusable(value, action) {
  if (value.error || (value.code !== undefined && ![0, 200].includes(Number(value.code)))) return false;
  return (Array.isArray(value.list) && value.list.length > 0)
    || (action === 'home' && Array.isArray(value.class) && value.class.length > 0);
}

// Session-local directory responses: no player-response cache or disk persistence.
// Coalesce pending reads even when a caller explicitly requests fresh details.
export class CatVodResponseCache {
  constructor({ ttlMs = 15000, maxEntries = 64, maxBytes = 2 * 1024 * 1024, now = () => performance.now() } = {}) {
    this.ttlMs = ttlMs;
    this.maxEntries = maxEntries;
    this.maxBytes = maxBytes;
    this.now = now;
    this.entries = new Map();
    this.pending = new Map();
    this.bytes = 0;
  }

  #remove(key) {
    const value = this.entries.get(key);
    if (value) this.bytes -= value.bytes;
    this.entries.delete(key);
  }

  async load(key, action, operation, fresh = false) {
    if (key === null) return operation();
    const pending = this.pending.get(key);
    if (pending) return structuredClone(await pending);
    const cached = this.entries.get(key);
    if (!fresh && cached && cached.expiresAt > this.now()) {
      this.entries.delete(key);
      this.entries.set(key, cached);
      return structuredClone(cached.value);
    }
    this.#remove(key);
    const request = Promise.resolve().then(operation).then(value => {
      if (reusable(value, action)) {
        const bytes = Buffer.byteLength(key) + Buffer.byteLength(JSON.stringify(value));
        if (bytes <= this.maxBytes) {
          while (this.entries.size && (this.entries.size >= this.maxEntries || this.bytes + bytes > this.maxBytes)) {
            this.#remove(this.entries.keys().next().value);
          }
          this.entries.set(key, { value, bytes, expiresAt: this.now() + this.ttlMs });
          this.bytes += bytes;
        }
      }
      return value;
    }).finally(() => this.pending.delete(key));
    this.pending.set(key, request);
    return structuredClone(await request);
  }
}
