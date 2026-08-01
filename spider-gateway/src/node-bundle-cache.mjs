import { createHash, randomUUID } from "node:crypto";
import dns from "node:dns/promises";
import { createReadStream } from "node:fs";
import { mkdir, open, rename, stat, unlink } from "node:fs/promises";
import path from "node:path";
import { GatewayError } from "./errors.mjs";
import { isPrivateAddress } from "./jar-reference.mjs";
import { readBoundedBuffer } from "./bounded-response.mjs";

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

function parseBundleURL(value, allowCredentials = false) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new GatewayError("INVALID_BUNDLE_URL", "CatVod bundle must be an HTTP or HTTPS URL", 400);
  }
  url.hash = "";
  if (!["http:", "https:"].includes(url.protocol)) {
    throw new GatewayError("INVALID_BUNDLE_URL", "CatVod bundle must be an HTTP or HTTPS URL", 400);
  }
  let authorization = "";
  if (url.username || url.password) {
    if (!allowCredentials) {
      throw new GatewayError("INVALID_BUNDLE_URL", "CatVod redirect credentials are not allowed", 400);
    }
    let username;
    let password;
    try {
      username = decodeURIComponent(url.username);
      password = decodeURIComponent(url.password);
    } catch {
      throw new GatewayError("INVALID_BUNDLE_URL", "CatVod Basic Auth credentials are invalid", 400);
    }
    authorization = `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`;
    url.username = "";
    url.password = "";
  }
  return { url, authorization };
}

function assertAllowedURL(url, allowedURLs, allowHTTP) {
  if (url.protocol !== "https:" && !allowHTTP) {
    throw new GatewayError("INVALID_BUNDLE_URL", "Allowlisted CatVod bundles must use HTTPS", 400);
  }
  if (!allowedURLs.includes(url.toString())) {
    throw new GatewayError("BUNDLE_URL_NOT_ALLOWED", "CatVod bundle URL is not in the allowlist", 403);
  }
}

async function validateBundleDestination(url, allowPrivateNetwork) {
  if (allowPrivateNetwork) return;
  let addresses;
  try {
    addresses = await dns.lookup(url.hostname, { all: true, verbatim: true });
  } catch {
    throw new GatewayError("BUNDLE_DNS_FAILED", "Unable to resolve the CatVod bundle host", 400);
  }
  if (addresses.length === 0 || addresses.some(({ address }) => isPrivateAddress(address))) {
    throw new GatewayError("BUNDLE_PRIVATE_ADDRESS", "CatVod bundle downloads from private networks are blocked", 403);
  }
}

export class NodeBundleCache {
  constructor(options) {
    this.cacheDir = options.nodeBundleCacheDir;
    this.allowedURLs = options.nodeBundleAllowedURLs.map(
      (value) => parseBundleURL(value, true).url.toString()
    );
    this.allowHTTP = options.nodeBundleAllowHTTP === true;
    this.allowPrivateNetwork = options.nodeBundleAllowPrivateNetwork === true;
    this.fetchValue = options.fetchValue || fetch;
    this.maxBytes = options.nodeBundleMaxBytes;
    this.timeoutMs = options.nodeBundleDownloadTimeoutMs;
    this.inflight = new Map();
    this.completed = new Map();
    this.artifactCacheTTLms = options.artifactCacheTTLms || 30_000;
    this.artifactCacheEntries = options.artifactCacheEntries || 32;
  }

  async resolve(reference) {
    const parsed = parseBundleURL(reference.trim(), true);
    assertAllowedURL(parsed.url, this.allowedURLs, this.allowHTTP);
    const key = createHash("sha256")
      .update(parsed.url.toString())
      .update("\0")
      .update(parsed.authorization)
      .digest("hex");
    const cached = this.completed.get(key);
    if (cached && cached.expiresAt > Date.now()) {
      this.completed.delete(key);
      this.completed.set(key, cached);
      return cached.artifact;
    }
    this.completed.delete(key);
    const current = this.inflight.get(key);
    if (current) return current;
    const operation = this.#resolve(parsed, key)
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

  async #resolve(parsed, cacheKey) {
    const requestedURL = parsed.url;
    let bundleURL = requestedURL;
    let expectedMD5 = null;
    if (requestedURL.pathname.endsWith(".js.md5")) {
      const manifest = await this.#fetchText(requestedURL, 1024, parsed.authorization);
      const match = manifest.trim().match(/^[a-fA-F0-9]{32}$/);
      if (!match) throw new GatewayError("INVALID_BUNDLE_MANIFEST", "CatVod MD5 manifest is invalid", 422);
      expectedMD5 = match[0].toLowerCase();
      bundleURL = new URL(requestedURL);
      bundleURL.pathname = bundleURL.pathname.slice(0, -4);
      assertAllowedURL(bundleURL, this.allowedURLs, this.allowHTTP);
    }
    if (!bundleURL.pathname.endsWith(".js")) {
      throw new GatewayError("INVALID_BUNDLE_URL", "CatVod bundle URL must end with .js or .js.md5", 400);
    }

    await mkdir(this.cacheDir, { recursive: true, mode: 0o700 });
    const filePath = path.join(this.cacheDir, `${cacheKey}.js`);
    try {
      const info = await stat(filePath);
      if (info.isFile() && info.size > 0 && info.size <= this.maxBytes) {
        const digests = await fileDigests(filePath);
        if (!expectedMD5 || digests.md5 === expectedMD5) {
          return { path: filePath, digest: digests.sha256, sourceURL: bundleURL.toString() };
        }
      }
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }

    const temporaryPath = path.join(this.cacheDir, `.${cacheKey}.${randomUUID()}.part`);
    try {
      const result = await this.#download(bundleURL, temporaryPath, parsed.authorization);
      if (expectedMD5 && result.md5 !== expectedMD5) {
        throw new GatewayError("BUNDLE_CHECKSUM_MISMATCH", "CatVod bundle checksum does not match", 422);
      }
      await rename(temporaryPath, filePath);
      return { path: filePath, digest: result.sha256, sourceURL: bundleURL.toString() };
    } catch (error) {
      await unlink(temporaryPath).catch(() => {});
      throw error;
    }
  }

  async #fetchText(url, maximumBytes, authorization) {
    const response = await this.#fetch(url, authorization);
    const buffer = await readBoundedBuffer(response, {
      maximumBytes,
      code: "BUNDLE_MANIFEST_TOO_LARGE",
      message: "CatVod manifest is too large"
    });
    return buffer.toString("utf8");
  }

  async #download(initialURL, destination, authorization) {
    const response = await this.#fetch(initialURL, authorization);
    const declared = Number.parseInt(response.headers.get("content-length") || "0", 10);
    if (declared > this.maxBytes) throw new GatewayError("BUNDLE_TOO_LARGE", "CatVod bundle exceeds the size limit", 413);
    const file = await open(destination, "wx", 0o600);
    const sha256 = createHash("sha256");
    const md5 = createHash("md5");
    let total = 0;
    try {
      for await (const chunk of response.body) {
        total += chunk.length;
        if (total > this.maxBytes) throw new GatewayError("BUNDLE_TOO_LARGE", "CatVod bundle exceeds the size limit", 413);
        sha256.update(chunk);
        md5.update(chunk);
        await file.write(chunk);
      }
    } finally {
      await file.close();
    }
    if (total === 0) throw new GatewayError("INVALID_BUNDLE", "CatVod bundle is empty", 422);
    return { sha256: sha256.digest("hex"), md5: md5.digest("hex") };
  }

  async #fetch(initialURL, authorization) {
    let currentURL = initialURL;
    const credentialOrigin = initialURL.origin;
    for (let redirects = 0; redirects <= MAX_REDIRECTS; redirects += 1) {
      await validateBundleDestination(currentURL, this.allowPrivateNetwork);
      const requestAuthorization = currentURL.origin === credentialOrigin ? authorization : "";
      const response = await this.fetchValue(currentURL, {
        redirect: "manual",
        signal: AbortSignal.timeout(this.timeoutMs),
        headers: {
          "user-agent": "tvbox-spider-gateway/0.2",
          ...(requestAuthorization ? { authorization: requestAuthorization } : {})
        }
      }).catch((error) => {
        if (error.name === "TimeoutError") throw new GatewayError("BUNDLE_DOWNLOAD_TIMEOUT", "CatVod download timed out", 504);
        throw new GatewayError("BUNDLE_DOWNLOAD_FAILED", "Unable to download the CatVod bundle", 502, { cause: error });
      });
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        const location = response.headers.get("location");
        if (!location || redirects === MAX_REDIRECTS) throw new GatewayError("BUNDLE_REDIRECT_FAILED", "Invalid CatVod redirect", 502);
        await response.body?.cancel().catch(() => {});
        const redirected = parseBundleURL(new URL(location, currentURL).toString());
        assertAllowedURL(redirected.url, this.allowedURLs, this.allowHTTP);
        currentURL = redirected.url;
        continue;
      }
      if (!response.ok || !response.body) {
        throw new GatewayError("BUNDLE_DOWNLOAD_FAILED", `CatVod server returned HTTP ${response.status}`, 502);
      }
      return response;
    }
    throw new GatewayError("BUNDLE_REDIRECT_FAILED", "Too many CatVod redirects", 502);
  }
}
