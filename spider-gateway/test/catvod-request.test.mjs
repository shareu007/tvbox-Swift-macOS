import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { CatVodManager } from "../src/catvod-manager.mjs";
import { validateInvokeRequest } from "../src/request.mjs";

function homeRequest(api) {
  return {
    version: 1, action: "home",
    site: { key: "fixture", api, jar: "https://example.com/index.js.md5", ext: "" },
    arguments: { filter: true }
  };
}

test("CatVod accepts single-segment Unicode provider names", () => {
  for (const api of ["/spider/测试分类/3", "/spider/视频_电影-2/4", "/spider/café/3", "/spider/demo/3"]) {
    assert.equal(validateInvokeRequest(homeRequest(api)).site.api, api);
  }
});

test("Unicode provider support still rejects path traversal, encoded segments and query strings", () => {
  for (const api of [
    "/spider/../3", "/spider/测试/../3", "/spider/测试%2f分类/3",
    "/spider/%E6%B5%8B%E8%AF%95/3", "/spider/测试 分类/3", "/spider/测试/3?x=1",
    "/spider/测试/3#fragment", "/spider/测试\\分类/3", "/spider/测试\n/3",
    "/spider/测试/3\n", "/spider/测试/3\r\n"
  ]) {
    assert.throws(() => validateInvokeRequest(homeRequest(api)), error => error.code === "UNSUPPORTED_API");
  }
});

test("remote CatVod code cannot observe bundle credentials in invocation messages", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "catvod-request-privacy-test-"));
  const manager = new CatVodManager({
    nodeBundleRuntimeDir: root, workerTimeoutMs: 2000,
    catVodIdleMs: 60000, catVodMaxSessions: 1, workerMaxLineBytes: 1024 * 1024
  });
  t.after(async () => {
    const exited = [...manager.sessions.values()]
      .filter(session => !session.closed)
      .map(session => once(session.process, "close"));
    manager.close();
    await Promise.all(exited);
    await rm(root, { recursive: true, force: true });
  });
  const artifact = {
    path: fileURLToPath(new URL("../fixtures/fake-catvod-observe-request.js", import.meta.url)),
    digest: "request-privacy"
  };
  const result = await manager.invoke(artifact, {
    key: "fixture", api: "/spider/fixture/3", ext: "required-provider-config",
    jar: "https://demo:secret@source.example/index.js.md5?token=private",
    unusedSecret: "parent-only"
  }, "home", { filter: true });
  assert.deepEqual(result.observedSite, {
    key: "fixture", api: "/spider/fixture/3", ext: "required-provider-config"
  });
});
