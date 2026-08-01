import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { mkdir, open, rename, stat, unlink } from "node:fs/promises";
import path from "node:path";
import { GatewayError } from "./errors.mjs";
import { parseJarReference, validateJarDestination } from "./jar-reference.mjs";

const MAX_REDIRECTS = 4;

async function fileDigests(filePath) {
  const sha256 = createHash("sha256");
  const md5 = createHash("md5");
  for await (const chunk of createReadStream(filePath)) {
    sha256.update(chunk);
    md5.update(chunk);
  }
  return { sha256: sha256.digest("hex"), md5: md5.digest("hex") };
}

export class JarCache {
  constructor(options) {
    this.cacheDir = options.cacheDir;
    this.allowedHosts = options.jarAllowedHosts;
    this.allowPrivateNetwork = options.allowPrivateNetwork;
    this.maxBytes = options.jarMaxBytes;
    this.timeoutMs = options.jarDownloadTimeoutMs;
    this.inflight = new Map();
    this.completed = new Map();
    this.artifactCacheTTLms = options.artifactCacheTTLms || 30_000;
    this.artifactCacheEntries = options.artifactCacheEntries || 32;
  }

  async resolve(reference) {
    const parsed = parseJarReference(reference);
    const key = createHash("sha256")
      .update(parsed.url.toString())
      .update("\0")
      .update(parsed.checksum?.algorithm || "")
      .update("\0")
      .update(parsed.checksum?.value || "")
      .digest("hex");
    const cached = this.completed.get(key);
    if (cached && cached.expiresAt > Date.now()) {
      this.completed.delete(key);
      this.completed.set(key, cached);
      return cached.artifact;
    }
    this.completed.delete(key);
    const existing = this.inflight.get(key);
    if (existing) return existing;
    const operation = this.#resolve(key, parsed)
      .then((artifact) => {
        this.#remember(key, artifact);
        return artifact;
      })
      .finally(() => this.inflight.delete(key));
    this.inflight.set(key, operation);
    return operation;
  }

  #remember(key, artifact) {
    this.completed.delete(key);
    this.completed.set(key, {
      artifact,
      expiresAt: Date.now() + this.artifactCacheTTLms
    });
    while (this.completed.size > this.artifactCacheEntries) {
      this.completed.delete(this.completed.keys().next().value);
    }
  }

  async #resolve(key, parsed) {
    await mkdir(this.cacheDir, { recursive: true, mode: 0o700 });
    const filePath = path.join(this.cacheDir, `${key}.jar`);
    try {
      const info = await stat(filePath);
      if (info.isFile() && info.size > 0 && info.size <= this.maxBytes) {
        const digests = await fileDigests(filePath);
        if (!parsed.checksum || digests[parsed.checksum.algorithm] === parsed.checksum.value) {
          return { path: filePath, digest: digests.sha256, sourceURL: parsed.url.toString() };
        }
      }
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }

    const temporaryPath = path.join(this.cacheDir, `.${key}.${randomUUID()}.part`);
    try {
      const result = await this.#download(parsed.url, temporaryPath);
      if (parsed.checksum && result.digests[parsed.checksum.algorithm] !== parsed.checksum.value) {
        throw new GatewayError("JAR_CHECKSUM_MISMATCH", "The downloaded JAR checksum does not match", 422);
      }
      await rename(temporaryPath, filePath);
      return { path: filePath, digest: result.digests.sha256, sourceURL: result.finalURL };
    } catch (error) {
      await unlink(temporaryPath).catch(() => {});
      throw error;
    }
  }

  async #download(initialURL, temporaryPath) {
    let currentURL = initialURL;
    for (let redirects = 0; redirects <= MAX_REDIRECTS; redirects += 1) {
      await validateJarDestination(currentURL, {
        allowedHosts: this.allowedHosts,
        allowPrivateNetwork: this.allowPrivateNetwork
      });

      const response = await fetch(currentURL, {
        redirect: "manual",
        signal: AbortSignal.timeout(this.timeoutMs),
        headers: { "user-agent": "tvbox-spider-gateway/0.1" }
      }).catch((error) => {
        if (error.name === "TimeoutError") {
          throw new GatewayError("JAR_DOWNLOAD_TIMEOUT", "JAR download timed out", 504);
        }
        throw new GatewayError("JAR_DOWNLOAD_FAILED", "Unable to download the Spider JAR", 502, { cause: error });
      });

      if ([301, 302, 303, 307, 308].includes(response.status)) {
        const location = response.headers.get("location");
        if (!location || redirects === MAX_REDIRECTS) {
          throw new GatewayError("JAR_REDIRECT_FAILED", "Too many or invalid JAR redirects", 502);
        }
        currentURL = new URL(location, currentURL);
        if (!["http:", "https:"].includes(currentURL.protocol) || currentURL.username || currentURL.password) {
          throw new GatewayError("INVALID_JAR_URL", "The JAR redirect target is not allowed", 403);
        }
        continue;
      }
      if (!response.ok || !response.body) {
        throw new GatewayError("JAR_DOWNLOAD_FAILED", `JAR server returned HTTP ${response.status}`, 502);
      }

      const declaredLength = Number.parseInt(response.headers.get("content-length") || "0", 10);
      if (declaredLength > this.maxBytes) {
        throw new GatewayError("JAR_TOO_LARGE", "The Spider JAR exceeds the configured size limit", 413);
      }

      const file = await open(temporaryPath, "wx", 0o600);
      const sha256 = createHash("sha256");
      const md5 = createHash("md5");
      let total = 0;
      let firstChunk = true;
      try {
        for await (const chunk of response.body) {
          total += chunk.length;
          if (total > this.maxBytes) {
            throw new GatewayError("JAR_TOO_LARGE", "The Spider JAR exceeds the configured size limit", 413);
          }
          if (firstChunk) {
            firstChunk = false;
            if (chunk.length < 2 || chunk[0] !== 0x50 || chunk[1] !== 0x4b) {
              throw new GatewayError("INVALID_JAR", "The downloaded file is not a JAR/ZIP archive", 422);
            }
          }
          sha256.update(chunk);
          md5.update(chunk);
          await file.write(chunk);
        }
      } finally {
        await file.close();
      }
      if (total === 0) throw new GatewayError("INVALID_JAR", "The downloaded JAR is empty", 422);
      return {
        finalURL: currentURL.toString(),
        digests: { sha256: sha256.digest("hex"), md5: md5.digest("hex") }
      };
    }
    throw new GatewayError("JAR_REDIRECT_FAILED", "Too many JAR redirects", 502);
  }
}
