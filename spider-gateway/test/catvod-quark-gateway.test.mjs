import assert from "node:assert/strict";
import test from "node:test";
import { loadConfig } from "../src/config.mjs";
import { createGateway } from "../src/server.mjs";

function episode(mode = "original") {
  return Buffer.from(JSON.stringify({ providerId: "quark", shareId: "fixture-share", fileId: "fixture-file",
    mode, playToken: JSON.stringify({ shareId: "fixture-share", fid: "fixture-file", stoken: "fixture-token",
      shareFidToken: "fixture-file-token", fileName: "movie.mp4" }) })).toString("base64");
}

async function setup(t, options = {}) {
  const observed = { requests: [], sourceCalls: 0, saves: 0, folderName: null, savedFiles: [] };
  const gateway = createGateway(loadConfig({ token: "fixture-gateway", cloudConfig: {
    quarkCookie: options.missingCookie ? "" : "fixture-cookie"
  } }), {
    nodeBundleCache: { resolve: async () => ({ path: "fixture", digest: "fixture" }) },
    catVod: { invoke: async () => { observed.sourceCalls += 1; return { url: "", message: "source has no cookie" }; }, close() {} },
    fetchValue: async (rawURL, request) => {
      const url = new URL(rawURL);
      assert.equal(url.hostname, "drive-pc.quark.cn", "Only Quark receives account credentials");
      assert.equal(request.headers.cookie, "fixture-cookie");
      observed.requests.push(url.pathname);
      if (options.expired) return new Response(null, { status: 401 });
      if (url.pathname.endsWith("/share/sharepage/detail")) return Response.json({ data: { list: options.missingFile ? [] : [{
        fid: "fixture-file", share_fid_token: "fixture-fresh-file-token", file_name: "movie.mp4", size: 10 * 1024 * 1024
      }] } });
      if (url.pathname.endsWith("/file/sort")) return Response.json({ data: { list:
        url.searchParams.get("pdir_fid") === "0"
          ? (observed.folderName ? [{ dir: 1, fid: "fixture-cache", file_name: observed.folderName }] : [])
          : observed.savedFiles
      } });
      if (url.pathname.endsWith("/file")) {
        observed.folderName = JSON.parse(request.body).file_name;
        assert.doesNotMatch(observed.folderName, /fixture-cookie/);
        return Response.json({ data: { fid: "fixture-cache" } });
      }
      if (url.pathname.endsWith("/share/sharepage/save")) {
        observed.saves += 1;
        assert.deepEqual(JSON.parse(request.body).fid_token_list, ["fixture-fresh-file-token"]);
        return Response.json({ data: { task_id: "fixture-task" } });
      }
      if (url.pathname.endsWith("/task")) {
        observed.savedFiles = [{ fid: "fixture-saved-file", file_name: "movie.mp4", size: 10 * 1024 * 1024 }];
        return Response.json({ data: { save_as: { save_as_top_fids: ["fixture-saved-file"] } } });
      }
      if (url.pathname.endsWith("/file/download")) {
        if (options.sizeLimit) return Response.json({ code: 23018, message: "upstream diagnostic must be hidden" }, { status: options.sizeLimit });
        return Response.json({ data: [{ fid: "fixture-saved-file", download_url: "https://media.quark.cn/original.mp4" }] });
      }
      if (url.pathname.endsWith("/file/v2/play")) return Response.json({ data: { video_list: [{
        resolution: "high", video_info: { url: "https://video.example.test/transcode.m3u8" }
      }] } });
      assert.fail("Unexpected fixture operation");
    }
  });
  await new Promise(resolve => gateway.server.listen(0, "127.0.0.1", resolve));
  t.after(() => gateway.close());
  return { observed, play: async (mode = "original", verifyResource = false) => {
    const response = await fetch(`http://127.0.0.1:${gateway.server.address().port}/v1/spider/invoke`, {
      method: "POST", headers: { "content-type": "application/json", authorization: "Bearer fixture-gateway" },
      body: JSON.stringify({ version: 1, action: "player", site: {
        key: "fixture", api: "/spider/wogg/3", jar: "https://example.test/index.js.md5", ext: ""
      }, arguments: { flag: "fixture", id: episode(mode), vipFlags: [], verifyResource } })
    });
    return { status: response.status, body: await response.json() };
  } };
}

test("CatVod Quark playback uses saved credentials in the parent instead of the remote source", async t => {
  const { play, observed } = await setup(t);
  const result = await play();
  assert.equal(result.status, 200);
  assert.equal(result.body.url, "https://media.quark.cn/original.mp4");
  assert.equal(result.body.header.cookie, "fixture-cookie");
  assert.equal(observed.sourceCalls, 0);
  assert.equal(observed.saves, 1);
});

test("availability checks do not transfer cloud files or send account credentials", async t => {
  const { play, observed } = await setup(t);
  const result = await play("original", true);
  assert.equal(result.status, 200);
  assert.equal(result.body.verification, "needs-playback");
  assert.equal(observed.sourceCalls, 0);
  assert.equal(observed.saves, 0);
  assert.deepEqual(observed.requests, []);
});

test("CatVod speed mode uses transcode quality options without leaking Cookie to another media host", async t => {
  const { play, observed } = await setup(t);
  const result = await play("speed");
  assert.equal(result.status, 200);
  assert.equal(result.body.url, "https://video.example.test/transcode.m3u8");
  assert.equal(result.body.header.cookie, undefined);
  assert.equal(result.body.qualityOptions[0].name, "高清");
  assert.equal(observed.requests.some(p => p.endsWith("/file/download")), false);
  assert.equal(observed.sourceCalls, 0);
});

for (const status of [400, 200]) {
  test(`Quark size restriction over HTTP ${status} falls back without saving a second copy`, async t => {
    const { play, observed } = await setup(t, { sizeLimit: status });
    const result = await play();
    assert.equal(result.status, 200);
    assert.equal(result.body.url, "https://video.example.test/transcode.m3u8");
    assert.equal(result.body.playbackNotice, "quark-original-size-limit");
    assert.equal(observed.saves, 1);
    assert.equal(observed.sourceCalls, 0);
  });
}

test("A missing or expired Quark login is reported before remote execution", async t => {
  for (const options of [{ missingCookie: true }, { expired: true }]) {
    const { play, observed } = await setup(t, options);
    const result = await play();
    assert.equal(result.status, 401);
    assert.equal(result.body.code, "CLOUD_AUTH_REQUIRED");
    assert.equal(observed.sourceCalls, 0);
    assert.equal(observed.saves, 0);
  }
});

test("A file no longer in the share never starts an account write or leaks diagnostics", async t => {
  const { play, observed } = await setup(t, { missingFile: true });
  const result = await play();
  assert.equal(result.status, 502);
  assert.equal(result.body.code, "CLOUD_PLAYBACK_FAILED");
  assert.equal(observed.saves, 0);
  assert.equal(observed.sourceCalls, 0);
  assert.doesNotMatch(JSON.stringify(result.body), /fixture-cookie|fixture-token/);
});

test("Concurrent playback of one CatVod file reuses its isolated copy without deletion", async t => {
  const { play, observed } = await setup(t);
  const results = await Promise.all([play("speed"), play("speed")]);
  assert.equal(results.every(result => result.status === 200), true);
  assert.equal(observed.saves, 1);
  assert.equal(observed.requests.some(p => p.endsWith("/file/delete")), false);
});

test("User changes in a CatVod cache folder are preserved and cannot play a different file", async t => {
  const { play, observed } = await setup(t);
  assert.equal((await play("speed")).status, 200);
  observed.savedFiles[0].file_name = "unrelated.mp4";
  const second = await play("speed");
  assert.equal(second.status, 502);
  assert.equal(second.body.code, "CLOUD_PLAYBACK_FAILED");
  assert.equal(observed.saves, 1);
  assert.equal(observed.savedFiles[0].file_name, "unrelated.mp4");
  assert.equal(observed.requests.some(p => p.endsWith("/file/delete")), false);
});
