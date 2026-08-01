import { timingSafeEqual } from "node:crypto";
import http from "node:http";
import { asGatewayError, GatewayError } from "./errors.mjs";
import { JarCache } from "./jar-cache.mjs";
import { CatVodManager } from "./catvod-manager.mjs";
import { NodeBundleCache } from "./node-bundle-cache.mjs";
import { validateCatalogRequest, validateInvokeRequest } from "./request.mjs";
import { WorkerManager } from "./worker-manager.mjs";
import { cloudPanSite, handleCloudPanAction, isCloudPanSite } from "./cloud-pan.mjs";
import { handlePanSearchAction, isPanSearchSite } from "./pan-search.mjs";

function sendJSON(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
    "x-content-type-options": "nosniff"
  });
  response.end(body);
}

function tokenMatches(header, expected) {
  if (!expected) return true;
  const prefix = "Bearer ";
  if (typeof header !== "string" || !header.startsWith(prefix)) return false;
  const actualBuffer = Buffer.from(header.slice(prefix.length));
  const expectedBuffer = Buffer.from(expected);
  return actualBuffer.length === expectedBuffer.length && timingSafeEqual(actualBuffer, expectedBuffer);
}

async function readJSON(request, maximumBytes) {
  const contentType = request.headers["content-type"] || "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new GatewayError("UNSUPPORTED_MEDIA_TYPE", "Content-Type must be application/json", 415);
  }
  const declared = Number.parseInt(request.headers["content-length"] || "0", 10);
  if (declared > maximumBytes) throw new GatewayError("REQUEST_TOO_LARGE", "Request body is too large", 413);
  const chunks = [];
  let total = 0;
  for await (const chunk of request) {
    total += chunk.length;
    if (total > maximumBytes) throw new GatewayError("REQUEST_TOO_LARGE", "Request body is too large", 413);
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new GatewayError("INVALID_JSON", "Request body contains invalid JSON", 400);
  }
}

export function createGateway(config, dependencies = {}) {
  const jarCache = dependencies.jarCache || new JarCache(config);
  const workers = dependencies.workers || new WorkerManager(config);
  const nodeBundleCache = dependencies.nodeBundleCache || new NodeBundleCache(config);
  // Third-party CatVod code runs in a separate process that never receives
  // account cookies or refresh tokens. Built-in cloud actions stay here in the
  // trusted parent process.
  const catVod = dependencies.catVod || new CatVodManager({ ...config, cloudConfig: {} });
  const trustedFetch = dependencies.fetchValue || fetch;
  const cloudCredentials = {
    quarkCookie: String(config.cloudConfig?.quarkCookie || "")
  };
  const server = http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url || "/", "http://gateway.local");
      if (request.method === "GET" && url.pathname === "/health") {
        sendJSON(response, 200, {
          status: "ok",
          protocol: 1,
          workerConfigured: Boolean(config.workerCommand),
          catVodConfigured: true
        });
        return;
      }
      if (request.method !== "POST" || !["/v1/spider/invoke", "/v1/catvod/catalog"].includes(url.pathname)) {
        throw new GatewayError("NOT_FOUND", "Route not found", 404);
      }
      if (!tokenMatches(request.headers.authorization, config.token)) {
        throw new GatewayError("UNAUTHORIZED", "Invalid or missing Gateway token", 401);
      }

      const body = await readJSON(request, config.requestBodyMaxBytes);
      if (url.pathname === "/v1/catvod/catalog") {
        const catalog = validateCatalogRequest(body);
        const artifact = await nodeBundleCache.resolve(catalog.bundle);
        const result = await catVod.catalog(artifact);
        let sites = Array.isArray(result?.sites)
          ? result.sites.map((site) => ({ ...site, type: 3, jar: catalog.bundle }))
          : [];
        if (!sites.some((site) => isCloudPanSite(site))) {
          sites = [...sites, { ...cloudPanSite, jar: catalog.bundle }];
        }
        sendJSON(response, 200, { sites });
        return;
      }

      const invoke = validateInvokeRequest(body);
      if (invoke.site.api.startsWith("/spider/")) {
        if (isCloudPanSite(invoke.site) || isPanSearchSite(invoke.site)) {
          const options = {
            action: invoke.action,
            argumentsValue: invoke.arguments,
            site: invoke.site,
            credentials: cloudCredentials,
            fetchValue: trustedFetch,
            searchEndpoint: config.panSouEndpoint
          };
          const result = isPanSearchSite(invoke.site)
            ? await handlePanSearchAction(options)
            : await handleCloudPanAction(options);
          sendJSON(response, 200, result);
          return;
        }
        const artifact = await nodeBundleCache.resolve(invoke.site.jar);
        sendJSON(response, 200, await catVod.invoke(artifact, invoke.site, invoke.action, invoke.arguments));
      } else {
        const artifact = await jarCache.resolve(invoke.site.jar);
        sendJSON(response, 200, await workers.invoke(artifact, invoke.site, invoke.action, invoke.arguments));
      }
    } catch (error) {
      const gatewayError = asGatewayError(error);
      sendJSON(response, gatewayError.status, { code: gatewayError.code, message: gatewayError.message });
    }
  });
  server.requestTimeout = Math.max(
    config.workerTimeoutMs + Math.max(config.jarDownloadTimeoutMs, config.nodeBundleDownloadTimeoutMs) + 5_000,
    30_000
  );
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;

  return {
    server,
    async listen() {
      await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(config.port, config.host, () => {
          server.off("error", reject);
          resolve();
        });
      });
      return server.address();
    },
    async close() {
      workers.close();
      catVod.close();
      if (!server.listening) return;
      await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
    }
  };
}
