import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { CatVodManager } from "../src/catvod-manager.mjs";

async function setup(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), "catvod-config-test-"));
  const manager = new CatVodManager({
    nodeBundleRuntimeDir: root,
    workerTimeoutMs: 2000,
    catVodIdleMs: 60000,
    catVodMaxSessions: 1,
    workerMaxLineBytes: 1024 * 1024,
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
    path: fileURLToPath(new URL("../fixtures/fake-catvod-config.js", import.meta.url)),
    digest: "config",
  };
  return ext => manager.invoke(artifact, { key: "config", api: "/spider/config/3", ext }, "home", { filter: true });
}

test("legacy provider initialization supplies an empty guest cookie", async t => {
  const invoke = await setup(t);
  assert.equal((await invoke("guest")).list[0].vod_id, "guest");
});

test("switching route extension A to B to A restores A initialization", async t => {
  const invoke = await setup(t);
  assert.equal((await invoke("A")).list[0].vod_id, "A");
  assert.equal((await invoke("B")).list[0].vod_id, "B");
  assert.equal((await invoke("A")).list[0].vod_id, "A");
});

test("failed initialization invalidates the previous route configuration", async t => {
  const invoke = await setup(t);
  assert.equal((await invoke("A")).list[0].vod_id, "A");
  await assert.rejects(invoke("fail"), /fixture init failed/);
  assert.equal((await invoke("A")).list[0].vod_id, "A");
});
