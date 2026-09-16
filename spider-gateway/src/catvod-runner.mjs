import { createRequire } from "node:module";
import { writeSync } from "node:fs";
import { readFile } from "node:fs/promises";
import readline from "node:readline";
import { pathToFileURL } from "node:url";
import { readBoundedText } from "./bounded-response.mjs";
import { startParentWatchdog } from "./process-lifecycle.mjs";

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function patchBundle(source) {
  const legacyLifecycle = source.match(
    /var ([A-Za-z_$][\w$]*)=null,[\s\S]{0,1000}?;async function ([A-Za-z_$][\w$]*)\(t\)\{\1=/
  );
  const modernLifecycle = legacyLifecycle ? null : source.match(
    /var ([A-Za-z_$][\w$]*)=null;async function ([A-Za-z_$][\w$]*)\([^)]*\)\{\1&&await ([A-Za-z_$][\w$]*)\(\);/
  );
  if (!legacyLifecycle && !modernLifecycle) {
    throw new Error("Unsupported CatVod bundle lifecycle");
  }

  let serverName;
  let startName;
  let stopName;
  let startExport;
  let patched = source;
  if (legacyLifecycle) {
    [, serverName, startName] = legacyLifecycle;
    const stopMatch = source.match(
      new RegExp(`async function ([A-Za-z_$][\\w$]*)\\(\\)\\{${escapeRegex(serverName)}&&`)
    );
    if (!stopMatch) throw new Error("Unsupported CatVod bundle stop lifecycle");
    stopName = stopMatch[1];
    const listenPattern = new RegExp(
      `(${escapeRegex(serverName)}\\.register\\([A-Za-z_$][\\w$]*\\)),${escapeRegex(serverName)}\\.listen\\(\\{port:process\\.env\\.DEV_HTTP_PORT\\|\\|0,host:"127\\.0\\.0\\.1"\\}\\)`
    );
    if (!listenPattern.test(source)) throw new Error("Unsupported CatVod bundle listener");
    patched = source.replace(
      listenPattern,
      `$1,await ${serverName}.ready(),globalThis.__catvodServer=${serverName}`
    );
    startExport = startName;
  } else {
    [, serverName, startName, stopName] = modernLifecycle;
    const stopPattern = new RegExp(
      `async function ${escapeRegex(stopName)}\\(\\)\\{${escapeRegex(serverName)}&&`
    );
    if (!stopPattern.test(source)) throw new Error("Unsupported CatVod bundle stop lifecycle");
    const listenerPattern = new RegExp(
      `,await [A-Za-z_$][\\w$]*\\(Number\\(process\\.env\\.DEV_HTTP_PORT\\|\\|process\\.env\\.PORT\\|\\|9988\\)\\)\\}async function ${escapeRegex(stopName)}`
    );
    if (!listenerPattern.test(source)) throw new Error("Unsupported CatVod bundle listener");
    patched = source.replace(
      listenerPattern,
      `,await ${serverName}.ready(),globalThis.__catvodServer=${serverName}}async function ${stopName}`
    );
    // Newer bundles take a large internal default config. Passing the legacy
    // cloud credential object would replace that config instead of extending it.
    startExport = `()=>${startName}()`;
  }

  const addressPattern = new RegExp(
    `${escapeRegex(serverName)}\\.address=function\\(\\)\\{let ([A-Za-z_$][\\w$]*)=this\\.server\\.address\\(\\);`
  );
  const addressMatch = patched.match(addressPattern);
  if (addressMatch) {
    patched = patched.replace(
      addressPattern,
      `${serverName}.address=function(){let ${addressMatch[1]}=this.server.address()||{address:"127.0.0.1",port:0};`
    );
  }
  const exportMarker = "0&&(module.exports={start,stop});";
  if (!patched.includes(exportMarker)) throw new Error("Unsupported CatVod bundle exports");
  patched = patched.replace(
    exportMarker,
    `globalThis.__catvodExports={start:${startExport},stop:${stopName}};`
  );
  return patched;
}

export function actionRequest(site, action, args) {
  const base = site.api.replace(/\/$/, "");
  switch (action) {
    case "home": return { path: `${base}/home`, payload: { filter: args.filter } };
    case "category": return { path: `${base}/category`, payload: { id: args.tid, page: args.page, filter: args.filter, filters: args.extend } };
    case "detail": return { path: `${base}/detail`, payload: { id: args.ids } };
    case "search": return { path: `${base}/search`, payload: { wd: args.keyword, quick: args.quick, page: args.page } };
    case "player": return { path: `${base}/play`, payload: { flag: args.flag, id: args.id, flags: args.vipFlags } };
    default: throw new Error(`Unsupported action: ${action}`);
  }
}

export function normalizePlayerResult(result, episodeID) {
  const currentURL = Array.isArray(result?.url) ? result.url.find(Boolean) : result?.url;
  if (currentURL) return result;
  try {
    const directURL = new URL(episodeID);
    if (!["http:", "https:"].includes(directURL.protocol)) return result;
    return { ...result, parse: 0, jx: 0, url: episodeID };
  } catch {
    return result;
  }
}

function htmlAttribute(value) {
  return value
    .replaceAll("&amp;", "&")
    .replaceAll("&#39;", "'")
    .replaceAll("&quot;", '"');
}

export async function resolvePlayerResult(site, result, episodeID, fetchValue = fetch) {
  const normalized = normalizePlayerResult(result, episodeID);
  if (site?.api !== "/spider/xb6v/3") return normalized;

  try {
    const configuredBase = typeof site.ext === "string" && /^https?:\/\//i.test(site.ext)
      ? site.ext
      : "https://www.xb6v.com/";
    const episodeURL = new URL(episodeID, configuredBase);
    const pageResponse = await fetchValue(episodeURL, {
      headers: { "user-agent": "Mozilla/5.0" }
    });
    if (!pageResponse.ok) return normalized;
    const page = await readBoundedText(pageResponse);
    const frameMatch = page.match(/<iframe\b[^>]*\bsrc=["']([^"']+)["']/i);
    if (!frameMatch) return normalized;

    const frameURL = new URL(htmlAttribute(frameMatch[1]), episodeURL);
    const frameResponse = await fetchValue(frameURL, {
      headers: { "user-agent": "Mozilla/5.0", referer: episodeURL.href }
    });
    if (!frameResponse.ok) return normalized;
    const frame = await readBoundedText(frameResponse);
    const mediaMatch = frame.match(/\bconst\s+url\s*=\s*(["'])(.*?)\1\s*;/s);
    if (!mediaMatch) return normalized;

    const mediaURL = new URL(htmlAttribute(mediaMatch[2]), frameURL);
    if (!["http:", "https:"].includes(mediaURL.protocol)) return normalized;
    return { ...normalized, parse: 0, jx: 0, url: mediaURL.href };
  } catch {
    return normalized;
  }
}

// A route can hold mutable parser state shared by its category/detail handlers.
// Keep requests to that route ordered while allowing different sites to overlap.
export function createSiteRequestQueue() {
  const tails = new Map();
  return function enqueue(siteAPI, operation) {
    const previous = tails.get(siteAPI) || Promise.resolve();
    const result = previous.then(operation);
    const tail = result.then(() => {}, () => {});
    tails.set(siteAPI, tail);
    tail.then(() => {
      if (tails.get(siteAPI) === tail) tails.delete(siteAPI);
    });
    return result;
  };
}

async function main() {
  const bundlePath = process.argv[2];
  if (!bundlePath) throw new Error("Bundle path is required");
  // fd 3 is a dedicated control channel. Third-party bundles may write logs to
  // stdout even after console is replaced, so stdout cannot carry protocol data.
  const writeLine = (value) => writeSync(3, value);
  const log = (...values) => process.stderr.write(`${values.map(String).join(" ").slice(0, 2048)}\n`);
  console.log = log;
  console.info = log;
  console.warn = log;
  console.error = log;
  globalThis.catServerFactory = undefined;
  globalThis.catDartServerPort = () => 0;

  const source = await readFile(bundlePath, "utf8");
  const patched = patchBundle(source);
  const localRequire = createRequire(pathToFileURL(bundlePath));
  new Function("require", "module", "exports", patched)(localRequire, { exports: {} }, {});
  if (!globalThis.__catvodExports?.start) throw new Error("CatVod start export is unavailable");
  // Account credentials remain in the trusted Gateway parent process. Remote
  // CatVod bundles receive only an empty compatibility configuration.
  await globalThis.__catvodExports.start({
    pans: { list: [] },
    cms: { list: [] },
    sites: { list: [] }
  });
  const server = globalThis.__catvodServer;
  if (!server?.inject) throw new Error("CatVod injection server is unavailable");
  const initialized = new Set();
  const initializing = new Map();

  async function inject(method, route, payload) {
    let request = server.inject()[method.toLowerCase()](route);
    if (payload !== undefined) request = request.payload(payload);
    const response = await request;
    let value;
    if (!response.body || response.body.trim() === "") value = {};
    else {
      try { value = response.json(); } catch { throw new Error(`CatVod returned invalid JSON for ${route}`); }
    }
    if (response.statusCode >= 400) throw new Error(value?.message || `CatVod returned HTTP ${response.statusCode}`);
    return value;
  }

  async function handle(message) {
    if (message.type === "catalog") {
      const config = await inject("get", "/config");
      const sites = Array.isArray(config?.video?.sites) ? config.video.sites : [];
      return { sites };
    }
    if (message.type !== "invoke") throw new Error("Unsupported runner request");
    const site = message.site;
    const initKey = `${site.api}\0${site.ext || ""}`;
    if (!initialized.has(initKey)) {
      let initialization = initializing.get(initKey);
      if (!initialization) {
        initialization = inject("post", `${site.api.replace(/\/$/, "")}/init`, { ext: site.ext || "" })
          .then(() => initialized.add(initKey))
          .finally(() => initializing.delete(initKey));
        initializing.set(initKey, initialization);
      }
      await initialization;
    }
    const request = actionRequest(site, message.action, message.arguments);
    const result = await inject("post", request.path, request.payload);
    return message.action === "player"
      ? await resolvePlayerResult(site, result, message.arguments.id)
      : result;
  }

  const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  const active = new Set();
  const enqueueSiteRequest = createSiteRequestQueue();
  const maximumConcurrentRequests = 6;
  for await (const line of lines) {
    const task = (async () => {
      let message;
      try {
        message = JSON.parse(line);
        const result = await enqueueSiteRequest(
          message.site?.api || "__catalog__",
          () => handle(message)
        );
        writeLine(`${JSON.stringify({ id: message.id, ok: true, result })}\n`);
      } catch (error) {
        writeLine(`${JSON.stringify({ id: message?.id, ok: false, code: "CATVOD_ERROR", message: error.message || "CatVod execution failed" })}\n`);
      }
    })();
    active.add(task);
    task.finally(() => active.delete(task));
    if (active.size >= maximumConcurrentRequests) await Promise.race(active);
  }
  await Promise.allSettled(active);
  await globalThis.__catvodExports.stop?.();
}

startParentWatchdog(async () => {
  await globalThis.__catvodExports?.stop?.();
});

if (import.meta.url === pathToFileURL(process.argv[1] || "").href) {
  main().catch((error) => {
    process.stderr.write(`${error.stack || error}\n`);
    process.exitCode = 1;
  });
}
