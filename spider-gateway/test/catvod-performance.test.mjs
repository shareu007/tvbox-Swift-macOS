import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { CatVodManager } from '../src/catvod-manager.mjs';
import { CatVodResponseCache } from '../src/catvod-response-cache.mjs';
import { requiresPlaybackConfirmation } from '../src/readonly-player.mjs';

const artifact = {
  path: fileURLToPath(new URL('../fixtures/fake-catvod-performance.js', import.meta.url)),
  digest: 'performance-fixture'
};
const site = { key: 'performance', api: '/spider/performance/3', ext: '' };

async function setup(t, options = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'catvod-performance-test-'));
  const manager = new CatVodManager({
    nodeBundleRuntimeDir: root, workerTimeoutMs: 2000, catVodIdleMs: 60000,
    catVodMaxSessions: 1, workerMaxLineBytes: 1024 * 1024, ...options
  });
  t.after(async () => {
    const exited = [...manager.sessions.values()].filter(s => !s.closed).map(s => once(s.process, 'close'));
    manager.close();
    await Promise.all(exited);
    await rm(root, { recursive: true, force: true });
  });
  return manager;
}

test('concurrent identical detail loads share one provider request', async t => {
  const manager = await setup(t);
  const load = () => manager.invoke(artifact, site, 'detail', { ids: ['film'] });
  const [first, second] = await Promise.all([load(), load()]);
  assert.equal(first.generation, 1);
  assert.equal(second.generation, 1, 'Duplicate details must not wait in the provider queue twice');
  const warm = await load();
  assert.equal(warm.generation, 1, 'Opening a checked resource should reuse its recent detail');
});

test('fresh verification bypasses old details but simultaneous checks share the new request', async t => {
  const manager = await setup(t);
  const ordinary = () => manager.invoke(artifact, site, 'detail', { ids: ['film'], verifyResource: false });
  assert.equal((await ordinary()).generation, 1);
  const fresh = () => manager.invoke(artifact, site, 'detail', { ids: ['film'], verifyResource: true });
  const results = await Promise.all([fresh(), fresh()]);
  assert.deepEqual(results.map(value => value.generation), [2, 2]);
  assert.equal((await ordinary()).generation, 2);
});

test('expired responses reload and signed player responses are never cached', async t => {
  let clock = 100;
  const manager = await setup(t, { responseCacheOptions: { now: () => clock, ttlMs: 1000 } });
  const load = () => manager.invoke(artifact, site, 'home', { filter: true });
  assert.equal((await load()).generation, 1);
  clock += 1001;
  assert.equal((await load()).generation, 2);
  const player = () => manager.invoke(artifact, site, 'player', { flag: 'direct', id: 'film', vipFlags: [] });
  assert.equal((await player()).generation, 3);
  assert.equal((await player()).generation, 4);
});

test('provider configuration, page and filters are isolated and key ordering is immaterial', async t => {
  const manager = await setup(t);
  const category = (extend, page = '1', ext = '') => manager.invoke(artifact, { ...site, ext }, 'category',
    { tid: 'movie', page, filter: true, extend });
  assert.equal((await category({ year: '2026', area: 'CN' })).generation, 1);
  assert.equal((await category({ area: 'CN', year: '2026' })).generation, 1);
  assert.equal((await category({ area: 'CN', year: '2025' })).generation, 2);
  assert.equal((await category({ area: 'CN', year: '2025' }, '2')).generation, 3);
  assert.equal((await category({ area: 'CN', year: '2025' }, '2', 'different-config')).generation, 4);
});

test('failed and empty responses are retried, and callers cannot mutate shared cached values', async () => {
  const cache = new CatVodResponseCache();
  let calls = 0;
  const load = operation => cache.load('fixture', 'detail', async () => { calls++; return operation(); });
  await assert.rejects(load(() => { throw new Error('fixture failure'); }));
  await load(() => ({ list: [] }));
  const result = await load(() => ({ list: [{ vod_id: 'film' }] }));
  result.list[0].vod_id = 'mutated';
  assert.equal((await load(() => assert.fail('cached response expected'))).list[0].vod_id, 'film');
  assert.equal(calls, 3);
});

test('response cache limits both entry count and byte size', async () => {
  const cache = new CatVodResponseCache({ maxEntries: 2, maxBytes: 150 });
  const response = { list: [{ vod_id: 'film' }] };
  for (const key of ['first', 'second', 'third']) await cache.load(key, 'detail', async () => response);
  assert.equal(cache.entries.size, 2);
  assert.equal(cache.entries.has('first'), false);
  await cache.load('huge', 'detail', async () => ({ list: [{ vod_id: 'x'.repeat(200) }] }));
  assert.equal(cache.entries.has('huge'), false);
  assert.ok(cache.bytes <= 150);
});

test('cloud routes, flags, descriptors and share links stay pending even inside ordinary sites', () => {
  for (const args of [
    { id: 'opaque', flag: '夸克原画' },
    { id: 'https://pan.quark.cn/s/fixture', flag: '直连' },
    { id: Buffer.from(JSON.stringify({ providerId: 'quark' })).toString('base64'), flag: '来源一' }
  ]) assert.equal(requiresPlaybackConfirmation(site, args), true);
  assert.equal(requiresPlaybackConfirmation({ api: '/spider/wogg/3' }, { id: 'opaque' }), true);
  assert.equal(requiresPlaybackConfirmation(site, { id: 'opaque', flag: '在线' }), false);
});
