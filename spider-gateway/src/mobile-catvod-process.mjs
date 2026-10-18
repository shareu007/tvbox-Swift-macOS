import { EventEmitter } from 'node:events';
import path from 'node:path';
import { PassThrough, Writable } from 'node:stream';
import { Worker } from 'node:worker_threads';

// The manager owns the same bounded request protocol on both platforms. iOS
// cannot spawn a process, so each untrusted bundle gets a disposable V8 worker.
export function createMobileCatVodProcess({ bundlePath, runtimeDir, runnerPath, maxLineBytes }) {
  const result = new EventEmitter();
  const control = new PassThrough();
  const permissions = [
    '--permission',
    `--allow-fs-read=${path.dirname(runnerPath)}`,
    `--allow-fs-read=${bundlePath}`,
    `--allow-fs-read=${runtimeDir}`,
    `--allow-fs-write=${runtimeDir}`
  ];
  // Workers do not inherit the parent's permission model. Explicitly start
  // them with their own file allowlist and no addons, subprocesses or workers.
  if (process.allowedNodeEnvironmentFlags.has('--allow-net')) permissions.push('--allow-net');
  const worker = new Worker(new URL('./mobile-catvod-worker.mjs', import.meta.url), {
    workerData: { bundlePath, runtimeDir, maxLineBytes },
    execArgv: permissions,
    env: { NODE_ENV: 'development', UNDICI_NO_WASM_SIMD: '1' },
    argv: [], stdout: true, stderr: true,
    resourceLimits: { maxOldGenerationSizeMb: 160, stackSizeMb: 4 },
    name: 'tvbox-catvod'
  });
  let closed = false;
  worker.stdout.resume();
  worker.stderr.resume();
  worker.on('message', line => {
    if (typeof line !== 'string' || Buffer.byteLength(line) > maxLineBytes) {
      result.emit('error', new Error('CatVod response exceeds the size limit'));
      void worker.terminate();
      return;
    }
    control.write(line);
  });
  worker.once('error', error => result.emit('error', error));
  worker.once('exit', code => {
    closed = true;
    control.end();
    result.emit('exit', code);
    result.emit('close', code);
  });
  result.stdin = new Writable({
    write(chunk, encoding, callback) {
      if (closed) return callback(new Error('CatVod worker is closed'));
      worker.postMessage({ line: chunk.toString('utf8') });
      callback();
    },
    final(callback) { worker.postMessage({ close: true }); callback(); }
  });
  result.stdio = [result.stdin, null, null, control];
  result.kill = () => { void worker.terminate(); };
  return result;
}
