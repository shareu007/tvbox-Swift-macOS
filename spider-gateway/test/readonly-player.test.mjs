import assert from 'node:assert/strict';
import test from 'node:test';
import { loadConfig } from '../src/config.mjs';
import { createGateway } from '../src/server.mjs';

async function setup(t) {
  const calls = [];
  const config = loadConfig({ token: 'fixture-gateway', cloudConfig: {} });
  config.port = 0;
  const gateway = createGateway(config, {
    nodeBundleCache: { resolve: async () => ({ digest: 'fixture', path: 'fixture' }) },
    catVod: {
      async invoke(artifact, site, action, args) {
        calls.push({ action, args });
        return { parse: 0, url: 'https://media.example.test/video.mp4', header: { Referer: 'https://example.test/' } };
      }, close() {}
    },
    fetchValue: async () => assert.fail('No account requests are allowed during verification')
  });
  const { port } = await gateway.listen();
  t.after(() => gateway.close());
  return { calls, invoke: async args => {
    const response = await fetch(`http://127.0.0.1:${port}/v1/spider/invoke`, {
      method: 'POST', headers: { 'content-type': 'application/json', authorization: 'Bearer fixture-gateway' },
      body: JSON.stringify({ version: 1, action: 'player', site: {
        key: 'fixture', api: '/spider/ordinary/3', jar: 'https://example.test/index.js.md5', ext: ''
      }, arguments: { id: 'opaque', flag: '在线', vipFlags: [], ...args } })
    });
    return { status: response.status, body: await response.json() };
  } };
}

test('readonly ordinary player requests resolve through the actual Gateway endpoint', async t => {
  const { calls, invoke } = await setup(t);
  const result = await invoke({ verifyResource: true });
  assert.equal(result.status, 200);
  assert.equal(result.body.url, 'https://media.example.test/video.mp4');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].action, 'player');
  assert.equal(calls[0].args.verifyResource, true);
});

test('cloud descriptors mixed into an ordinary source never reach remote or account code', async t => {
  const { calls, invoke } = await setup(t);
  const id = Buffer.from(JSON.stringify({ providerId: 'quark' })).toString('base64');
  const result = await invoke({ verifyResource: true, id });
  assert.equal(result.status, 200);
  assert.equal(result.body.verification, 'needs-playback');
  assert.equal(calls.length, 0);
});

test('read-only intent must be a boolean', async t => {
  const { calls, invoke } = await setup(t);
  assert.equal((await invoke({ verifyResource: 'true' })).status, 400);
  assert.equal(calls.length, 0);
});
