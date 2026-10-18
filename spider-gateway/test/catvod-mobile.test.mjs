import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { CatVodManager } from '../src/catvod-manager.mjs';
import { createMobileCatVodProcess } from '../src/mobile-catvod-process.mjs';

const artifact = {
  path: fileURLToPath(new URL('../fixtures/fake-catvod-mobile.js', import.meta.url)),
  digest: 'mobile-fixture'
};
const site = { key: 'mobile-fixture', api: '/spider/mobile/3', ext: 'first' };

async function setup(t, timeout = 3000) {
  const staging = fileURLToPath(new URL('../../build/DerivedData/Tests/MobileSpider/', import.meta.url));
  await mkdir(staging, { recursive: true });
  const root = await mkdtemp(path.join(staging, 'session-'));
  const manager = new CatVodManager({
    nodeBundleRuntimeDir: root, workerTimeoutMs: timeout, catVodIdleMs: 60000,
    catVodMaxSessions: 1, workerMaxLineBytes: 1024 * 1024,
    createProcess: createMobileCatVodProcess
  });
  t.after(async () => {
    manager.close();
    await new Promise(resolve => setTimeout(resolve, 100));
    await rm(root, { recursive: true, force: true });
  });
  return { manager, root };
}

test('mobile thread executes catalog, home, category, detail, search and player without a gateway process', async t => {
  const { manager, root } = await setup(t);
  assert.equal((await manager.catalog(artifact)).sites[0].key, site.key);
  const home = await manager.invoke(artifact, site, 'home', { filter: true });
  assert.equal(home.class[0].type_id, 'movie');
  assert.equal(home.list[0].vod_id, 'one');
  const category = await manager.invoke(artifact, site, 'category', { tid: 'movie', page: '2' });
  assert.equal(category.list[0].vod_id, 'movie2');
  const detail = await manager.invoke(artifact, site, 'detail', { ids: ['one'] });
  assert.equal(detail.list[0].vod_play_from, 'direct');
  const search = await manager.invoke(artifact, site, 'search', { keyword: 'query' });
  assert.equal(search.list[0].vod_id, 'query');
  const player = await manager.invoke(artifact, site, 'player', { id: 'https://media.example.test/fixture.mp4' });
  assert.equal(player.parse, 0);
  assert.equal(player.url, 'https://media.example.test/fixture.mp4');
  assert.equal(player.header.Referer, 'https://media.example.test/');
  const [session] = await readdir(root);
  assert.deepEqual(JSON.parse(await readFile(path.join(root, session, 'db.json'))), { ext: 'first' });
  assert.equal((await manager.invoke(artifact, { ...site, ext: 'second' }, 'search', { keyword: 'query' })).list[0].vod_name, 'second');
});

test('provider workers cannot read the application directory or use the native credential bridge', async t => {
  const { manager } = await setup(t);
  const value = await manager.invoke(artifact, site, 'search', { keyword: 'permissions' });
  assert.deepEqual(JSON.parse(value.list[0].vod_name), {
    fileDenied: true, fdDenied: true, esmDenied: true, bindingDenied: true, bridgeDenied: true, workerDenied: true, addonDenied: true
  });
});

test('a provider exception, exit or infinite loop cannot stop later mobile requests', async t => {
  const { manager } = await setup(t, 500);
  await assert.rejects(manager.invoke(artifact, site, 'search', { keyword: 'throw' }));
  await assert.rejects(manager.invoke(artifact, site, 'search', { keyword: 'exit' }));
  await assert.rejects(manager.invoke(artifact, site, 'search', { keyword: 'loop' }), { code: 'CATVOD_TIMEOUT' });
  const value = await manager.invoke(artifact, site, 'search', { keyword: 'recovered' });
  assert.equal(value.list[0].vod_id, 'recovered');
});
