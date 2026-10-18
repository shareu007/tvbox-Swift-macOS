import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';

// Native iOS and Node share one OS process. Node's path permissions explicitly
// exempt existing descriptors, so providers must not read/close native database
// descriptors. Patch the public fs modules before evaluating provider code.
export function restrictMobileFileDescriptors() {
  const owned = new Set();
  function denied() {
    const error = new Error('Native file descriptors are unavailable to providers');
    error.code = 'ERR_ACCESS_DENIED';
    throw error;
  }
  function check(value) {
    if (typeof value === 'number' && !owned.has(value)) denied();
  }
  const openSync = fs.openSync;
  fs.openSync = (...args) => {
    const fd = Reflect.apply(openSync, fs, args);
    owned.add(fd);
    return fd;
  };
  const open = fs.open;
  fs.open = (...args) => {
    const callback = args.pop();
    return Reflect.apply(open, fs, [...args, (error, fd) => {
      if (!error) owned.add(fd);
      callback(error, fd);
    }]);
  };
  const guarded = ['read', 'readv', 'write', 'writev', 'readFile', 'writeFile',
    'appendFile', 'truncate', 'ftruncate', 'fstat', 'fchmod', 'fchown', 'futimes',
    'fsync', 'fdatasync', 'close'];
  for (const name of guarded) {
    for (const key of [name, `${name}Sync`]) {
      const original = fs[key];
      if (typeof original !== 'function') continue;
      fs[key] = (...args) => {
        check(args[0]);
        if (name === 'close') owned.delete(args[0]);
        return Reflect.apply(original, fs, args);
      };
    }
  }
  for (const key of ['createReadStream', 'createWriteStream']) {
    const original = fs[key];
    fs[key] = (file, options, ...rest) => {
      check(options?.fd);
      return Reflect.apply(original, fs, [file, options, ...rest]);
    };
  }
  for (const key of ['readFile', 'writeFile', 'appendFile']) {
    const original = fs.promises[key];
    fs.promises[key] = (...args) => {
      check(args[0]);
      return Reflect.apply(original, fs.promises, args);
    };
  }
  // Public process.binding() bypasses the fs module and its descriptor checks.
  // Node's own internals use the separate, private internalBinding function.
  Object.defineProperty(process, 'binding', { value: denied, configurable: false, writable: false });
  for (const key of ['kill', 'abort', 'reallyExit', '_debugProcess']) {
    Object.defineProperty(process, key, { value: denied, configurable: false, writable: false });
  }
  // CatVod code can dynamically import a builtin. Its named ESM exports must
  // use the same guarded functions as require('fs') and the default export.
  syncBuiltinESMExports();
}
