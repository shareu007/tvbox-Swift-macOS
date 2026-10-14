import assert from "node:assert/strict";
import test from "node:test";
import { parseCatVodQuarkEpisode, resolveCatVodCloudPlayer } from "../src/catvod-cloud-player.mjs";

function descriptor(overrides = {}) {
  return { providerId: "quark", shareId: "fixture-share", fileId: "fixture-file", name: "movie.mp4",
    playToken: JSON.stringify({ fid: "fixture-file", shareFidToken: "fixture-file-token",
      shareId: "fixture-share", stoken: "fixture-share-token", fileName: "movie.mp4" }),
    mode: "original", quality: "original", ...overrides };
}
const encode = (value, encoding = "base64") => Buffer.from(JSON.stringify(value)).toString(encoding);

test("CatVod Quark contract accepts both base64 variants and preserves playback mode", () => {
  for (const encoding of ["base64", "base64url"]) {
    for (const mode of ["original", "speed"]) {
      const parsed = parseCatVodQuarkEpisode(encode(descriptor({ mode, quality: mode }), encoding));
      assert.equal(parsed.mode, mode);
      assert.deepEqual(parsed.file, { provider: "quark", shareId: "fixture-share", fileId: "fixture-file",
        fileToken: "fixture-file-token", stoken: "fixture-share-token", fileName: "movie.mp4" });
    }
  }
});

test("CatVod Quark contract does not intercept ordinary media or other cloud providers", async () => {
  for (const id of ["https://media.example.test/movie.mp4", "opaque-episode", encode([]),
    encode(null), encode(descriptor({ providerId: "uc" })), encode({ provider: "quark" }),
    encode(descriptor()) + "\n", encode(descriptor()) + " "] ) {
    assert.equal(parseCatVodQuarkEpisode(id), null);
    assert.equal(await resolveCatVodCloudPlayer({ id }, {}, () => assert.fail("Unexpected fetch")), null);
  }
});

test("CatVod Quark contract rejects malformed and inconsistent episodes before network access", async () => {
  const original = descriptor();
  const token = JSON.parse(original.playToken);
  for (const value of [descriptor({ playToken: "invalid" }), descriptor({ playToken: "null" }),
    descriptor({ playToken: "[]" }), descriptor({ fileId: "other" }), descriptor({ shareId: "other" }),
    descriptor({ mode: "unknown" }), descriptor({ playToken: JSON.stringify({ ...token, stoken: "" }) }),
    descriptor({ playToken: JSON.stringify({ ...token, fileName: "movie\r\n.mp4" }) }),
    descriptor({ playToken: JSON.stringify({ ...token, fid: "x".repeat(257) }) })]) {
    const id = encode(value);
    assert.throws(() => parseCatVodQuarkEpisode(id), { code: "INVALID_CLOUD_EPISODE" });
    await assert.rejects(resolveCatVodCloudPlayer({ id }, { quarkCookie: "fixture-cookie" },
      () => assert.fail("Unexpected fetch")), { code: "INVALID_CLOUD_EPISODE" });
  }
});

test("Missing Quark Cookie produces an actionable authentication error without executing a bundle", async () => {
  await assert.rejects(resolveCatVodCloudPlayer({ id: encode(descriptor()) }, {},
    () => assert.fail("Unexpected fetch")), { code: "CLOUD_AUTH_REQUIRED", status: 401 });
});

test("Expired Quark Cookie is distinguished from missing credentials", async () => {
  await assert.rejects(resolveCatVodCloudPlayer({ id: encode(descriptor()) },
    { quarkCookie: "fixture-expired-cookie" }, async (url, options) => {
      assert.equal(new URL(url).hostname, "drive-pc.quark.cn");
      assert.equal(options.headers.cookie, "fixture-expired-cookie");
      return new Response(null, { status: 401 });
    }), { code: "CLOUD_AUTH_REQUIRED", message: "夸克登录已失效，请在 TVBox 网盘设置中更新 Cookie" });
});

test("Quark playback failures do not return upstream private diagnostics", async () => {
  await assert.rejects(resolveCatVodCloudPlayer({ id: encode(descriptor()) },
    { quarkCookie: "fixture-cookie" }, async () => {
      throw new Error("https://private.example.test/?token=fixture-private Cookie=fixture-secret");
    }), (error) => {
      assert.equal(error.code, "CLOUD_PLAYBACK_FAILED");
      assert.doesNotMatch(error.message, /private\.example|fixture-private|fixture-secret/);
      return true;
    });
});

test("Baidu episodes explain the unsupported provider without requesting Quark credentials", async () => {
  const id = encode({ providerId: "baidu", shareId: "fixture-share", fileId: "fixture-file",
    playToken: JSON.stringify({ fsId: "fixture-file", uk: "fixture-owner", pwd: "fixture-code" }),
    mode: "original" });
  for (const credentials of [{}, { quarkCookie: "fixture-quark-cookie" }]) {
    await assert.rejects(resolveCatVodCloudPlayer({ id }, credentials,
      () => assert.fail("Do not transmit Quark credentials for Baidu playback")), {
      code: "CLOUD_PROVIDER_UNSUPPORTED", status: 422,
      message: "TVBox 暂未接入百度网盘播放，请选择夸克或普通影视线路；夸克 Cookie 不能用于百度网盘"
    });
  }
});
