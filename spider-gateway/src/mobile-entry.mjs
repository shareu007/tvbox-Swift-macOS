import path from 'node:path';
import { loadConfig } from './config.mjs';
import { createGateway } from './server.mjs';
import { CatVodManager } from './catvod-manager.mjs';
import { NodeBundleCache } from './node-bundle-cache.mjs';
import { createMobileCatVodProcess } from './mobile-catvod-process.mjs';

// This binding is available only on the native engine thread. Credentials never
// enter argv, environment variables, bootstrap files or provider workers.
export async function startMobileGateway(bridge, dependencies = {}) {
  const initial = JSON.parse(bridge.configuration());
  const config = loadConfig(initial);
  Object.assign(config, {
    host: '127.0.0.1', port: 0, workerCommand: '',
    cacheDir: path.join(initial.cacheRoot, 'jars'),
    nodeBundleCacheDir: path.join(initial.cacheRoot, 'bundles'),
    nodeBundleRuntimeDir: path.join(initial.cacheRoot, 'runtime'),
    nodeBundleAllowHTTP: initial.nodeBundleAllowedURLs.some(url => url.startsWith('http://')),
    catVodMaxSessions: 1, catVodIdleMs: 15000
  });
  const nodeBundleCache = new NodeBundleCache(config);
  const catVod = new CatVodManager({ ...config, createProcess: createMobileCatVodProcess });
  const gateway = createGateway(config, {
    nodeBundleCache, catVod, ...dependencies,
    beforeRequest() {
      const current = JSON.parse(bridge.configuration());
      nodeBundleCache.allowedURLs = current.nodeBundleAllowedURLs;
      nodeBundleCache.allowHTTP = current.nodeBundleAllowedURLs.some(url => url.startsWith('http://'));
      config.cloudConfig = current.cloudConfig || {};
      config.token = current.token;
    }
  });
  const address = await gateway.listen();
  bridge.ready(`http://127.0.0.1:${address.port}`);
  return gateway;
}

if (process.argv[1]?.endsWith('/mobile-entry.mjs')) {
  const bridge = process._linkedBinding('tvbox_mobile');
  startMobileGateway(bridge).catch(() => bridge.failed());
}
