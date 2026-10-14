import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { loadConfig } from "../src/config.mjs";
import { NodeBundleCache } from "../src/node-bundle-cache.mjs";

const bundle = "globalThis.fixture = true;";
const checksum = createHash("md5").update(bundle).digest("hex");
const entry = "http://source.example/index.js.md5";

async function setup(t, options = {}, responses = {}) {
  const directory = await mkdtemp(path.join(os.tmpdir(), "catvod-checksum-redirect-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const calls = [];
  const cache = new NodeBundleCache({
    nodeBundleCacheDir: directory,
    nodeBundleAllowedURLs: [entry, entry.slice(0, -4)],
    nodeBundleAllowHTTP: true,
    nodeBundleAllowChecksumRedirects: true,
    nodeBundleAllowPrivateNetwork: true,
    nodeBundleMaxBytes: 1024,
    nodeBundleDownloadTimeoutMs: 1000,
    ...options,
    fetchValue: async (url, request) => {
      calls.push({ url: url.toString(), authorization: request.headers.authorization || "" });
      if (url.pathname.endsWith(".js.md5")) return new Response(responses.manifest ?? checksum);
      if (url.pathname === "/index.js") {
        return new Response(null, {
          status: 302,
          headers: { location: responses.location ?? "http://cdn.example/opaque-payload" }
        });
      }
      if (responses.redirectLoop) {
        return new Response(null, { status: 302, headers: { location: "/opaque-payload" } });
      }
      return new Response(responses.body ?? bundle, { headers: { "content-type": "image/jpeg" } });
    }
  });
  return { cache, calls, directory };
}

test("checksum redirects are opt-in and bootstrap overrides require a boolean", () => {
  assert.equal(loadConfig().nodeBundleAllowChecksumRedirects, false);
  assert.equal(loadConfig({ nodeBundleAllowChecksumRedirects: true }).nodeBundleAllowChecksumRedirects, true);
  assert.throws(() => loadConfig({ nodeBundleAllowChecksumRedirects: "true" }), /must be a boolean/);
});

test("verified manifest allows a CDN script with opaque path and non-script MIME without forwarding credentials", async (t) => {
  const { cache, calls } = await setup(t);
  const artifact = await cache.resolve("http://demo:secret@source.example/index.js.md5");
  assert.equal(await readFile(artifact.path, "utf8"), bundle);
  assert.equal(artifact.sourceURL, entry.slice(0, -4));
  assert.deepEqual(calls.map(call => call.authorization), [
    `Basic ${Buffer.from("demo:secret").toString("base64")}`,
    `Basic ${Buffer.from("demo:secret").toString("base64")}`,
    ""
  ]);
});

test("checked HTTPS redirects work with HTTP and private networks disabled", async (t) => {
  const secureEntry = "https://8.8.8.8/index.js.md5";
  const { cache } = await setup(t, {
    nodeBundleAllowedURLs: [secureEntry, secureEntry.slice(0, -4)],
    nodeBundleAllowHTTP: false,
    nodeBundleAllowPrivateNetwork: false
  }, { location: "https://1.1.1.1/opaque-payload" });
  const artifact = await cache.resolve(secureEntry);
  assert.equal(await readFile(artifact.path, "utf8"), bundle);
});

test("checksum mismatch never publishes the redirected script to the cache", async (t) => {
  const { cache, directory } = await setup(t, {}, { body: "modified script" });
  await assert.rejects(cache.resolve(entry), error => error.code === "BUNDLE_CHECKSUM_MISMATCH");
  assert.deepEqual(await readdir(directory), []);
});

test("an invalid manifest is rejected before fetching its script", async (t) => {
  const { cache, calls } = await setup(t, {}, { manifest: "not a digest" });
  await assert.rejects(cache.resolve(entry), error => error.code === "INVALID_BUNDLE_MANIFEST");
  assert.equal(calls.length, 1);
});

test("a manifest cannot authorize an entry outside the exact allowlist", async (t) => {
  const { cache, calls } = await setup(t);
  await assert.rejects(cache.resolve("http://other.example/index.js.md5"), error => error.code === "BUNDLE_URL_NOT_ALLOWED");
  assert.equal(calls.length, 0);
});

test("manifest redirects cannot bypass the paired script allowlist", async (t) => {
  const { cache, calls } = await setup(t, { nodeBundleAllowedURLs: [entry] });
  await assert.rejects(cache.resolve(entry), error => error.code === "BUNDLE_URL_NOT_ALLOWED");
  assert.equal(calls.length, 1);
});

test("manifest scripts still require the redirect opt-in", async (t) => {
  const { cache } = await setup(t, { nodeBundleAllowChecksumRedirects: false });
  await assert.rejects(cache.resolve(entry), error => error.code === "BUNDLE_URL_NOT_ALLOWED");
});

test("unchecked JS keeps exact redirect allowlisting even when the option is enabled", async (t) => {
  const { cache, calls } = await setup(t);
  await assert.rejects(cache.resolve(entry.slice(0, -4)), error => error.code === "BUNDLE_URL_NOT_ALLOWED");
  assert.equal(calls.length, 1);
});

test("MD5 manifest redirects themselves remain exactly allowlisted", async (t) => {
  const { cache } = await setup(t);
  cache.fetchValue = async () => new Response(null, {
    status: 302, headers: { location: "http://cdn.example/index.js.md5" }
  });
  await assert.rejects(cache.resolve(entry), error => error.code === "BUNDLE_URL_NOT_ALLOWED");
});

test("a checked HTTPS script cannot redirect to unlisted HTTP even when HTTP is enabled", async (t) => {
  const secureEntry = entry.replace("http:", "https:");
  const { cache } = await setup(t, {
    nodeBundleAllowedURLs: [secureEntry, secureEntry.slice(0, -4)]
  });
  await assert.rejects(cache.resolve(secureEntry), error => error.code === "INVALID_BUNDLE_URL");
});

test("redirects cannot introduce new credentials or non-HTTP schemes", async (t) => {
  for (const location of ["http://demo:secret@cdn.example/opaque-payload", "file:///opaque-payload"]) {
    const { cache } = await setup(t, {}, { location });
    await assert.rejects(cache.resolve(entry), error => error.code === "INVALID_BUNDLE_URL");
  }
});

test("checked redirects still block private network destinations before a request", async (t) => {
  const publicEntry = "https://8.8.8.8/index.js.md5";
  const { cache, calls } = await setup(t, {
    nodeBundleAllowedURLs: [publicEntry, publicEntry.slice(0, -4)],
    nodeBundleAllowPrivateNetwork: false
  }, { location: "https://127.0.0.1/opaque-payload" });
  await assert.rejects(cache.resolve(publicEntry), error => error.code === "BUNDLE_PRIVATE_ADDRESS");
  assert.equal(calls.length, 2);
});

test("checked redirect loops are bounded and do not leave partial files", async (t) => {
  const { cache, calls, directory } = await setup(t, {}, { redirectLoop: true });
  await assert.rejects(cache.resolve(entry), error => error.code === "BUNDLE_REDIRECT_FAILED");
  assert.equal(calls.length, 6);
  assert.deepEqual(await readdir(directory), []);
});

test("redirected chunked bodies still obey the download size limit", async (t) => {
  const { cache, directory } = await setup(t, { nodeBundleMaxBytes: 4 });
  await assert.rejects(cache.resolve(entry), error => error.code === "BUNDLE_TOO_LARGE");
  assert.deepEqual(await readdir(directory), []);
});

test("checked HTTPS redirects cannot downgrade even to an explicitly allowlisted HTTP URL", async t => {
  const secureEntry = entry.replace("http:", "https:");
  const target = "http://cdn.example/opaque-payload";
  const { cache } = await setup(t, {
    nodeBundleAllowedURLs: [secureEntry, secureEntry.slice(0, -4), target]
  }, { location: target });
  await assert.rejects(cache.resolve(secureEntry), error => error.code === "INVALID_BUNDLE_URL");
});
