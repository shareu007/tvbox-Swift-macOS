import fs from 'node:fs';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import { parentPort, workerData } from 'node:worker_threads';
import { runCatVod } from './catvod-runner.mjs';
import { restrictMobileFileDescriptors } from './mobile-file-descriptors.mjs';

const { bundlePath, runtimeDir, maxLineBytes } = workerData;
restrictMobileFileDescriptors();
// chdir() is process-wide and unavailable in workers. Resolve legacy relative
// provider databases inside this session without changing the native app's cwd.
process.cwd = () => runtimeDir;
const twoPaths = new Set(['copyFile', 'cp', 'link', 'rename', 'symlink']);
const onePath = new Set(['access', 'appendFile', 'chmod', 'chown', 'exists', 'lchmod',
  'lchown', 'lstat', 'lutimes', 'mkdir', 'mkdtemp', 'open', 'openAsBlob', 'opendir',
  'readFile', 'readdir', 'readlink', 'realpath', 'rm', 'rmdir', 'stat', 'statfs',
  'truncate', 'unlink', 'utimes', 'watch', 'watchFile', 'unwatchFile', 'writeFile',
  'createReadStream', 'createWriteStream']);
const scopedPath = value => typeof value === 'string' && !path.isAbsolute(value)
  ? path.resolve(runtimeDir, value) : value;
function scopedFS(target) {
  return new Proxy(target, {
    get(object, property) {
      if (property === 'promises') return scopedFS(fs.promises);
      const value = object[property];
      const name = String(property).replace(/Sync$/, '');
      if (typeof value !== 'function' || (!onePath.has(name) && !twoPaths.has(name))) return value;
      return (...args) => {
        args[0] = scopedPath(args[0]);
        if (twoPaths.has(name)) args[1] = scopedPath(args[1]);
        return Reflect.apply(value, object, args);
      };
    }
  });
}
const input = new PassThrough();
parentPort.on('message', message => {
  if (message.close) input.end();
  else if (typeof message.line === 'string' && Buffer.byteLength(message.line) <= maxLineBytes) {
    input.write(message.line);
  } else {
    input.destroy(new Error('CatVod request exceeds the size limit'));
  }
});
try {
  await runCatVod(bundlePath, {
    input,
    writeLine: line => parentPort.postMessage(line),
    wrapRequire: original => name => {
      if (name === 'fs' || name === 'node:fs') return scopedFS(fs);
      if (name === 'fs/promises' || name === 'node:fs/promises') return scopedFS(fs.promises);
      return original(name);
    }
  });
} finally {
  parentPort.close();
}
