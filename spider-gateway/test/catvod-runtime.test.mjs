import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { setTimeout as delay } from 'node:timers/promises';
import { CatVodManager } from '../src/catvod-manager.mjs';

const artifact = {
  path: fileURLToPath(new URL('../fixtures/fake-catvod-home-cache.js', import.meta.url)),
  digest: 'cache-fixture'
};
const site = { key: 'cache-fixture', api: '/spider/cache/3', ext: '' };

async function setup(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'catvod-runtime-test-'));
  const managers = [];
  t.after(async () => {
    const exited = managers.flatMap(manager => [...manager.sessions.values()])
      .filter(session => !session.closed)
      .map(session => once(session.process, 'close'));
    managers.forEach(manager => manager.close());
    await Promise.all(exited);
    await rm(root, { recursive: true, force: true });
  });
  return { root, create() {
    const manager = new CatVodManager({
      nodeBundleRuntimeDir: root, workerTimeoutMs: 2000, catVodIdleMs: 60000,
      catVodMaxSessions: 1, workerMaxLineBytes: 1024 * 1024
    });
    managers.push(manager);
    return manager;
  }};
}

test('home ignores a truncated database left by a previous session', async (t) => {
  const { root, create } = await setup(t);
  const legacy = path.join(root, artifact.digest);
  await mkdir(legacy);
  await writeFile(path.join(legacy, 'db.json'), '');
  const result = await create().invoke(artifact, site, 'home', { filter: true });
  assert.equal(result.list.length, 1);
  assert.equal(result.class.length, 1);
  assert.equal(await readFile(path.join(legacy, 'db.json'), 'utf8'), '');
});

test('simultaneous managers never share a writable provider database', async (t) => {
  const { root, create } = await setup(t);
  const first = create();
  await first.invoke(artifact, site, 'home', { filter: true });
  const [firstDirectory] = await readdir(root);
  await writeFile(path.join(root, firstDirectory, 'db.json'), '');
  const second = create();
  const result = await second.invoke(artifact, site, 'home', { filter: true });
  assert.equal(result.list.length, 1);
  assert.equal((await readdir(root)).length, 2);
});

test('stopping a session removes its disposable database', async (t) => {
  const { root, create } = await setup(t);
  const manager = create();
  await manager.invoke(artifact, site, 'home', { filter: true });
  assert.equal((await readdir(root)).length, 1);
  const exited = once(manager.sessions.get(artifact.digest).process, 'close');
  manager.close();
  await exited;
  for (let attempt = 0; attempt < 100 && (await readdir(root)).length; attempt++) {
    await delay(10);
  }
  assert.deepEqual(await readdir(root), []);
});
