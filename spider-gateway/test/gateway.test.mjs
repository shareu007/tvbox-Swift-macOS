import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import http from "node:http";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { PassThrough, Readable } from "node:stream";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { loadConfig } from "../src/config.mjs";
import { JarCache } from "../src/jar-cache.mjs";
import { isPrivateAddress, parseJarReference } from "../src/jar-reference.mjs";
import { NodeBundleCache } from "../src/node-bundle-cache.mjs";
import { createGateway } from "../src/server.mjs";
import { actionRequest, normalizePlayerResult, patchBundle, resolvePlayerResult } from "../src/catvod-runner.mjs";
import {
  CatVodManager,
  catVodFilePermissionArguments,
  catVodPermissionArguments,
  isCatVodSessionIdle,
  safeProxyEnvironment
} from "../src/catvod-manager.mjs";
import { WorkerManager } from "../src/worker-manager.mjs";
import { cloudPanTestSupport, handleCloudPanAction, searchCloudResources } from "../src/cloud-pan.mjs";
import { handlePanSearchAction, parseKuafuSearchHTML } from "../src/pan-search.mjs";
import { hasLostParent } from "../src/process-lifecycle.mjs";
import { attachBoundedLineReader } from "../src/bounded-lines.mjs";
import { readBoundedText } from "../src/bounded-response.mjs";
import {
  MAXIMUM_SECURE_CONFIG_BYTES,
  parseBoundedJSONObject,
  readBoundedJSONObject
} from "../src/secure-config.mjs";

const fixtureWorker = fileURLToPath(new URL("../fixtures/fake-worker.mjs", import.meta.url));
const fixtureCatVodBundle = fileURLToPath(new URL("../fixtures/fake-catvod-bundle.js", import.meta.url));
const fakeJar = Buffer.from("PK\u0003\u0004fake-spider-jar");

test("bounded line reader rejects oversized unterminated output incrementally", () => {
  const stream = new PassThrough();
  const lines = [];
  let overflowed = false;
  attachBoundedLineReader(stream, {
    maximumBytes: 4,
    onLine: (line) => lines.push(line),
    onOverflow: () => { overflowed = true; }
  });

  stream.write("12");
  stream.write("345");
  assert.equal(overflowed, true);
  assert.deepEqual(lines, []);
  stream.destroy();
});

test("bounded response reader rejects chunked bodies before full buffering", async () => {
  const response = new Response(Readable.toWeb(Readable.from([
    Buffer.from("1234"),
    Buffer.from("5")
  ])));
  await assert.rejects(
    readBoundedText(response, { maximumBytes: 4 }),
    (error) => error?.code === "UPSTREAM_RESPONSE_TOO_LARGE"
  );
});

function baseConfig(overrides = {}) {
  return {
    host: "127.0.0.1",
    port: 0,
    token: "test-token",
    cacheDir: "",
    nodeBundleCacheDir: "",
    nodeBundleAllowedURLs: [
      "https://raw.githubusercontent.com/qist/tvbox/master/cat/dist/index.js",
      "https://raw.githubusercontent.com/qist/tvbox/master/cat/dist/index.js.md5"
    ],
    nodeBundleAllowHTTP: false,
    nodeBundleAllowPrivateNetwork: true,
    nodeBundleMaxBytes: 16 * 1024 * 1024,
    nodeBundleDownloadTimeoutMs: 2_000,
    nodeBundleRuntimeDir: "",
    jarAllowedHosts: [],
    allowPrivateNetwork: true,
    jarMaxBytes: 1024 * 1024,
    jarDownloadTimeoutMs: 2_000,
    requestBodyMaxBytes: 64 * 1024,
    workerCommand: process.execPath,
    workerArgs: [fixtureWorker],
    workerTimeoutMs: 2_000,
    workerIdleMs: 10_000,
    workerMaxSessions: 4,
    workerMaxLineBytes: 1024 * 1024,
    catVodIdleMs: 100,
    catVodMaxSessions: 1,
    ...overrides
  };
}

async function listen(server) {
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return `http://127.0.0.1:${server.address().port}`;
}

async function post(url, body, token = "test-token") {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify(body)
  });
  return { status: response.status, body: await response.json() };
}

function request(jar, action = "home", argumentsValue = { filter: true }) {
  return {
    version: 1,
    action,
    site: { key: "fixture", api: "csp_Fixture", jar, ext: "fixture-ext", quickSearch: true },
    arguments: argumentsValue
  };
}

function jsonResponse(value, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => null },
    json: async () => value
  };
}

test("parseJarReference accepts TVBox checksum suffixes", () => {
  const parsed = parseJarReference(`https://example.com/spider.jar;md5;${"a".repeat(32)}`);
  assert.equal(parsed.url.toString(), "https://example.com/spider.jar");
  assert.deepEqual(parsed.checksum, { algorithm: "md5", value: "a".repeat(32) });
});

test("private address detection blocks common local ranges", () => {
  assert.equal(isPrivateAddress("127.0.0.1"), true);
  assert.equal(isPrivateAddress("10.2.3.4"), true);
  assert.equal(isPrivateAddress("192.168.1.10"), true);
  assert.equal(isPrivateAddress("::ffff:127.0.0.1"), true);
  assert.equal(isPrivateAddress("::ffff:7f00:1"), true);
  assert.equal(isPrivateAddress("fe90::1"), true);
  assert.equal(isPrivateAddress("febf::1"), true);
  assert.equal(isPrivateAddress("8.8.8.8"), false);
  assert.equal(isPrivateAddress("2001:4860:4860::8888"), false);
});

test("patchBundle readies CatVod for injection without opening a listener", () => {
  const source = 'var A=null,B=1;async function C(t){A={},A.register(D),A.listen({port:process.env.DEV_HTTP_PORT||0,host:"127.0.0.1"})}async function E(){A&&(A.close()),A=null}0&&(module.exports={start,stop});';
  const patched = patchBundle(source);
  assert.match(patched, /await A\.ready\(\),globalThis\.__catvodServer=A/);
  assert.match(patched, /globalThis\.__catvodExports=\{start:C,stop:E\}/);
  assert.doesNotMatch(patched, /process\.env\.DEV_HTTP_PORT/);
});

test("patchBundle supports current CatVod lifecycle without replacing its default config", () => {
  const source = 'var S=null;async function A(e=D){S&&await Z();S=await F({config:e}),S.address=function(){let x=this.server.address();return x},await L(Number(process.env.DEV_HTTP_PORT||process.env.PORT||9988))}async function Z(){S&&(await S.close(),S=null)}async function L(e){await S.listen({port:e})}0&&(module.exports={start,stop});';
  const patched = patchBundle(source);

  assert.match(patched, /await S\.ready\(\),globalThis\.__catvodServer=S/);
  assert.match(patched, /globalThis\.__catvodExports=\{start:\(\)=>A\(\),stop:Z\}/);
  assert.match(
    patched,
    /this\.server\.address\(\)\|\|\{address:"127\.0\.0\.1",port:0\}/
  );
  assert.doesNotMatch(patched, /await L\(Number\(process\.env\.DEV_HTTP_PORT/);
});

test("patchBundle does not export account-provider helpers", () => {
  const source = 'var A=null,B=1;async function C(t){A={},A.register(D),A.listen({port:process.env.DEV_HTTP_PORT||0,host:"127.0.0.1"})}async function E(){A&&(A.close()),A=null}async function I(t){X(t.aliToken),Y(t.quarkCookie)}async function J(t,e="电影"){let n=[],l=[],r={};for(let u of t){}}async function P(t,e,n){if(t.indexOf(Q)>-1)return await R(t,e,n);if(t.indexOf(S)>-1)return await T(t,e,n)}function H(t){if(t.indexOf(Q)>-1)return{};if(t.indexOf(S)>-1)return U()}0&&(module.exports={start,stop});';
  const patched = patchBundle(source);
  assert.doesNotMatch(patched, /globalThis\.__catvodCloud/);
});

test("patchBundle supplies a virtual address when the injected CatVod server is not listening", () => {
  const source = 'var A=null,Z=1;async function B(t){A={},A.register(C),A.listen({port:process.env.DEV_HTTP_PORT||0,host:"127.0.0.1"})}async function D(){A&&(A.close()),A=null}A.address=function(){let e=this.server.address();return e};0&&(module.exports={start,stop});';
  const patched = patchBundle(source);

  assert.match(
    patched,
    /this\.server\.address\(\)\|\|\{address:"127\.0\.0\.1",port:0\}/
  );
});

test("CatVod runner never reads or forwards account credentials", async () => {
  const source = await readFile(new URL("../src/catvod-runner.mjs", import.meta.url), "utf8");
  const runtime = source.slice(source.indexOf("async function main"));
  assert.match(source, /pans: \{ list: \[\] \}/);
  assert.match(source, /cms: \{ list: \[\] \}/);
  assert.match(source, /sites: \{ list: \[\] \}/);
  assert.doesNotMatch(runtime, /quarkCookie|aliToken|fd: 4|cloudInitialization/);
  assert.doesNotMatch(source, /process\.env\.TVBOX_CLOUD_CONFIG/);
});

test("secure bootstrap parsing accepts objects and rejects invalid or oversized values", async () => {
  const parsed = await readBoundedJSONObject(
    Readable.from([Buffer.from('{"token":"secret"}')]),
    undefined,
    "Test bootstrap"
  );
  assert.deepEqual(parsed, { token: "secret" });
  assert.throws(() => parseBoundedJSONObject("[]"), /must be a JSON object/);
  assert.throws(
    () => parseBoundedJSONObject(Buffer.alloc(MAXIMUM_SECURE_CONFIG_BYTES + 1)),
    /exceeds the size limit/
  );
});

test("gateway bootstrap overrides are retained in memory and removed from child environments", async () => {
  const config = loadConfig({
    token: "pipe-token",
    cloudConfig: { quarkCookie: "pipe-cookie" },
    nodeBundleAllowedURLs: ["https://example.com/cat.js?token=private"]
  });
  assert.equal(config.token, "pipe-token");
  assert.deepEqual(config.cloudConfig, { quarkCookie: "pipe-cookie" });
  assert.deepEqual(config.nodeBundleAllowedURLs, ["https://example.com/cat.js?token=private"]);

  const managerSource = await readFile(new URL("../src/catvod-manager.mjs", import.meta.url), "utf8");
  assert.doesNotMatch(managerSource, /TVBOX_CLOUD_CONFIG:/);
  assert.doesNotMatch(managerSource, /cloudConfig|stdio\[4\]/);
  assert.match(managerSource, /stdio: \["pipe", "ignore", "ignore", "pipe"\]/);
});

test("CatVod child never receives cloud credentials", async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "catvod-secure-config-test-"));
  const runtimeDirectory = path.join(directory, "runtime");
  const manager = new CatVodManager(baseConfig({
    nodeBundleRuntimeDir: runtimeDirectory,
    cloudConfig: { quarkCookie: "pipe-cookie" }
  }));
  t.after(async () => {
    manager.close();
    await rm(directory, { recursive: true, force: true });
  });

  const result = await manager.catalog({
    path: fixtureCatVodBundle,
    digest: "secure-config-fixture"
  });

  assert.equal(result.sites[0].key, "no-secret");
});

test("parent lifecycle detects reparented gateway and runner processes", () => {
  assert.equal(hasLostParent(100, 100), false);
  assert.equal(hasLostParent(100, 1), true);
  assert.equal(hasLostParent(100, 101), true);
});

test("CatVod idle eviction waits for active requests and expires inactive sessions", () => {
  const session = { closed: false, pending: new Map(), lastUsedAt: 1_000 };
  assert.equal(isCatVodSessionIdle(session, 5_999, 5_000), false);
  assert.equal(isCatVodSessionIdle(session, 6_000, 5_000), true);
  session.pending.set("request", {});
  assert.equal(isCatVodSessionIdle(session, 10_000, 5_000), false);
  session.closed = true;
  assert.equal(isCatVodSessionIdle(session, 10_000, 5_000), true);
});

test("closed managers reject new sessions without leaving child processes", async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "closed-manager-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const config = baseConfig({ nodeBundleRuntimeDir: directory });
  const artifact = { path: "/fixture/index.js", digest: "fixture" };
  const site = { key: "fixture", api: "csp_Fixture", ext: "" };

  const catVod = new CatVodManager(config);
  catVod.close();
  await assert.rejects(
    catVod.catalog(artifact),
    (error) => error?.code === "CATVOD_STOPPED"
  );

  const workers = new WorkerManager(config);
  workers.close();
  await assert.rejects(
    workers.invoke(artifact, site, "home", {}),
    (error) => error?.code === "WORKER_STOPPED"
  );

  const startingWorkers = new WorkerManager({
    ...config,
    workerArgs: ["-e", "process.stdin.resume()"],
    workerTimeoutMs: 5_000
  });
  const pendingInitialization = startingWorkers.invoke(artifact, site, "home", {});
  startingWorkers.close();
  await assert.rejects(
    pendingInitialization,
    (error) => error?.code === "WORKER_STOPPED"
  );
});

test("allowlisted CatVod bundles use Basic Auth only on their credential origin", async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "catvod-basic-auth-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const bundle = "globalThis.fixture = true;";
  const expectedMD5 = createHash("md5").update(bundle).digest("hex");
  const expectedAuthorization = `Basic ${Buffer.from("demo:secret").toString("base64")}`;
  const calls = [];
  const cache = new NodeBundleCache({
    ...baseConfig({
      nodeBundleCacheDir: directory,
      nodeBundleAllowedURLs: [
        "http://source.example/index.js.md5",
        "http://source.example/index.js",
        "https://cdn.example/payload.js"
      ],
      nodeBundleAllowHTTP: true,
      nodeBundleAllowPrivateNetwork: true
    }),
    fetchValue: async (url, options) => {
      calls.push({
        url: url.toString(),
        authorization: options.headers.authorization || ""
      });
      if (url.pathname.endsWith(".js.md5")) {
        return new Response(expectedMD5);
      }
      if (url.hostname === "source.example") {
        return new Response(null, {
          status: 302,
          headers: { location: "https://cdn.example/payload.js" }
        });
      }
      return new Response(bundle);
    }
  });

  const artifact = await cache.resolve(
    "http://demo:secret@source.example/index.js.md5"
  );

  assert.equal(await readFile(artifact.path, "utf8"), bundle);
  assert.equal(artifact.sourceURL, "http://source.example/index.js");
  assert.deepEqual(calls, [
    {
      url: "http://source.example/index.js.md5",
      authorization: expectedAuthorization
    },
    {
      url: "http://source.example/index.js",
      authorization: expectedAuthorization
    },
    {
      url: "https://cdn.example/payload.js",
      authorization: ""
    }
  ]);
  assert.doesNotMatch(artifact.path, /demo|secret/);
});

test("CatVod bundle redirects must also be explicitly allowlisted", async (t) => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "catvod-redirect-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const cache = new NodeBundleCache({
    ...baseConfig({
      nodeBundleCacheDir: directory,
      nodeBundleAllowedURLs: ["https://source.example/index.js"],
      nodeBundleAllowPrivateNetwork: true
    }),
    fetchValue: async () => new Response(null, {
      status: 302,
      headers: { location: "https://cdn.example/payload.js" }
    })
  });

  await assert.rejects(
    cache.resolve("https://source.example/index.js"),
    (error) => error?.code === "BUNDLE_URL_NOT_ALLOWED"
  );
});

test("cloud search does not initialize account providers", async () => {
  let initializations = 0;
  const result = await handleCloudPanAction({
    action: "search",
    argumentsValue: { keyword: "电影" },
    cloud: {},
    initializeCloud: async () => { initializations += 1; },
    fetchValue: async () => ({
      ok: true,
      json: async () => ({ code: 0, data: { merged_by_type: { quark: [], aliyun: [], 123: [] } } })
    })
  });
  assert.deepEqual(result, { list: [] });
  assert.equal(initializations, 0);
});

test("Kuafu search parser keeps supported cloud links and ignores unrelated links", () => {
  const result = parseKuafuSearchHTML(`
    <div class="search-item">
      <a class="search-item-title" href="https://pan.quark.cn/s/demo" title="流浪地球 4K">ignored</a>
    </div>
    <a class="search-item-title" href="https://example.com/not-cloud" title="广告">广告</a>
    <a class="search-item-title extra" href="https://www.alipan.com/s/ali">阿里版本</a>
  `);

  assert.equal(result.length, 2);
  assert.equal(result[0].vod_name, "流浪地球 4K");
  assert.equal(result[0].vod_remarks, "夸克网盘");
  assert.equal(cloudPanTestSupport.decodePayload(result[0].vod_id).provider, "quark");
  assert.equal(result[1].vod_name, "阿里版本");
});

test("Kuafu pan search uses HTML endpoint without initializing cloud accounts", async () => {
  let initializations = 0;
  const result = await handlePanSearchAction({
    action: "search",
    argumentsValue: { keyword: "电影" },
    site: { api: "/spider/pansearch/3", ext: "{\"engine\":\"kuafu\"}" },
    cloud: {},
    initializeCloud: async () => { initializations += 1; },
    fetchValue: async (url) => {
      assert.equal(url.searchParams.get("q"), "电影");
      return {
        ok: true,
        text: async () => '<a class="search-item-title" href="https://pan.quark.cn/s/demo" title="电影 4K">电影</a>'
      };
    }
  });

  assert.equal(result.list.length, 1);
  assert.equal(initializations, 0);
});

test("Funletu protocol maps direct Quark shares into native cloud results", async () => {
  const result = await handlePanSearchAction({
    action: "search",
    argumentsValue: { keyword: "电影" },
    site: { api: "/spider/pansearch/3", ext: "{\"engine\":\"funletu\"}" },
    fetchValue: async (url, options) => {
      assert.equal(url, "https://v.funletu.com/search");
      assert.equal(options.method, "POST");
      assert.equal(JSON.parse(options.body).query.searchtext, "电影");
      return jsonResponse({
        data: [
          { valid: 0, title: "电影 4K", url: "https://pan.quark.cn/s/demo?entry=funletu" },
          { valid: 1, title: "已失效", url: "https://pan.quark.cn/s/expired" }
        ]
      });
    }
  });

  assert.equal(result.list.length, 1);
  assert.equal(result.list[0].vod_name, "电影 4K");
  assert.equal(result.list[0].vod_remarks, "夸克网盘");
  assert.equal(cloudPanTestSupport.decodePayload(result.list[0].vod_id).url, "https://pan.quark.cn/s/demo");
});

test("YYets protocol extracts Quark shares without classifying plain comments as cloud resources", async () => {
  const result = await handlePanSearchAction({
    action: "search",
    argumentsValue: { keyword: "流浪地球" },
    site: { api: "/spider/pansearch/3", ext: "{\"engine\":\"yyets\"}" },
    fetchValue: async (url) => {
      assert.equal(url.searchParams.get("keyword"), "流浪地球");
      return jsonResponse({
        comment: [
          {
            comment: "《流浪地球2》4K 原盘\nhttps://pan.quark.cn/s/demo\n普通说明，不是网盘"
          },
          {
            comment: "广告 https://example.com/not-cloud"
          }
        ]
      });
    }
  });

  assert.equal(result.list.length, 1);
  assert.equal(result.list[0].vod_name, "流浪地球2 4K 原盘");
  assert.equal(result.list[0].vod_remarks, "夸克网盘");
  assert.equal(cloudPanTestSupport.decodePayload(result.list[0].vod_id).provider, "quark");
});

test("KKPans public protocol keeps current Quark shares and forwards pagination", async () => {
  const result = await handlePanSearchAction({
    action: "search",
    argumentsValue: { keyword: "流浪地球", page: 2 },
    site: { api: "/spider/pansearch/3", ext: "{\"engine\":\"kkpans\"}" },
    fetchValue: async (url, options) => {
      assert.equal(url.origin + url.pathname, "https://www.kkpans.com/api/resources/public");
      assert.equal(url.searchParams.get("search"), "流浪地球");
      assert.equal(url.searchParams.get("platform"), "quark");
      assert.equal(url.searchParams.get("page"), "2");
      assert.equal(options.headers.referer, "https://www.kkpans.com/");
      return jsonResponse({
        data: [
          {
            file_name: "流浪地球 4K REMUX",
            target_platform: "quark",
            share_link: "https://pan.quark.cn/s/current",
            original_url: "https://pan.quark.cn/s/original",
            share_code: "A8c2"
          },
          {
            file_name: "声明错误的平台",
            target_platform: "aliyun",
            share_link: "https://pan.quark.cn/s/wrong-platform"
          },
          {
            file_name: "非网盘广告",
            target_platform: "quark",
            share_link: "https://example.com/ad"
          }
        ]
      });
    }
  });

  assert.equal(result.list.length, 1);
  assert.equal(result.list[0].vod_name, "流浪地球 4K REMUX");
  assert.equal(result.list[0].vod_remarks, "夸克网盘");
  const payload = cloudPanTestSupport.decodePayload(result.list[0].vod_id);
  assert.equal(payload.provider, "quark");
  assert.equal(payload.url, "https://pan.quark.cn/s/current?pwd=A8c2");
});

test("QuarkShare catalog resolves matching share IDs into native Quark results", async () => {
  const result = await handlePanSearchAction({
    action: "search",
    argumentsValue: { keyword: "短剧" },
    site: {
      api: "/spider/pansearch/3",
      ext: "{\"engine\":\"quarkshare\",\"listURL\":\"https://example.test/quarkshare.txt\"}"
    },
    fetchValue: async (url) => {
      assert.equal(url.toString(), "https://example.test/quarkshare.txt");
      return {
        ok: true,
        text: async () => [
          "self 我的夸克网盘",
          "885fd4ba2d92 每日短剧更新",
          "https://pan.quark.cn/s/demo 电影合集",
          "invalid 短剧坏数据"
        ].join("\n")
      };
    }
  });

  assert.equal(result.list.length, 1);
  assert.equal(result.list[0].vod_name, "每日短剧更新");
  assert.equal(
    cloudPanTestSupport.decodePayload(result.list[0].vod_id).url,
    "https://pan.quark.cn/s/885fd4ba2d92"
  );
});

test("pan search detail reuses Quark cloud detail implementation", async () => {
  const id = cloudPanTestSupport.encodePayload({
    provider: "quark",
    url: "https://pan.quark.cn/s/demo",
    password: "",
    note: "示例",
    image: ""
  });
  const result = await handlePanSearchAction({
    action: "detail",
    argumentsValue: { ids: [id] },
    site: { api: "/spider/pansearch/3", ext: "{\"engine\":\"kuafu\"}" },
    cloud: {},
    credentials: {},
    fetchValue: async (url) => {
      const value = new URL(url);
      if (value.pathname.endsWith("/share/sharepage/token")) {
        return jsonResponse({ code: 0, data: { stoken: "token" } });
      }
      return jsonResponse({ code: 0, data: { list: [{
        file: true,
        fid: "video",
        share_fid_token: "file-token",
        file_name: "正片.mp4",
        obj_category: "video",
        size: 100 * 1024 * 1024
      }] }, metadata: { _total: 1 } });
    }
  });

  assert.match(result.list[0].vod_play_from, /夸克网盘/);
});

test("cloud provider detail initializes credentials only when required", async () => {
  let initializations = 0;
  const id = cloudPanTestSupport.encodePayload({
    provider: "aliyun",
    url: "https://www.alipan.com/s/demo",
    note: "示例",
    image: ""
  });
  const result = await handleCloudPanAction({
    action: "detail",
    argumentsValue: { ids: [id] },
    cloud: { detail: async () => ({ "阿里": "第一集$https://example.test/video.m3u8" }) },
    initializeCloud: async () => { initializations += 1; }
  });
  assert.equal(result.list.length, 1);
  assert.equal(initializations, 1);
});

test("Quark search links preserve embedded extraction passwords", () => {
  const normalized = cloudPanTestSupport.normalizeShareURL(
    "https://pan.quark.cn/s/demo 提取码：A8c2"
  );
  assert.equal(new URL(normalized).searchParams.get("pwd"), "A8c2");
});

test("Quark detail lists nested videos without initializing the legacy cloud bundle", async () => {
  const requests = [];
  let initializations = 0;
  const fetchValue = async (url, options) => {
    const value = new URL(url);
    requests.push({ url: value, options });
    if (value.pathname.endsWith("/share/sharepage/token")) {
      assert.deepEqual(JSON.parse(options.body), { pwd_id: "demo", passcode: "A8c2" });
      return jsonResponse({ code: 0, data: { stoken: "share-token" } });
    }
    if (value.searchParams.get("pdir_fid") === "0") {
      return jsonResponse({ code: 0, data: { list: [
        { dir: true, fid: "folder", file_name: "正片" },
        {
          file: true,
          fid: "video-1",
          share_fid_token: "file-token-1",
          file_name: "第一集.mp4",
          obj_category: "video",
          size: 100 * 1024 * 1024
        }
      ] }, metadata: { _total: 2 } });
    }
    return jsonResponse({ code: 0, data: { list: [{
      file: true,
      fid: "video-2",
      share_fid_token: "file-token-2",
      file_name: "第二集.mkv",
      obj_category: "video",
      size: 200 * 1024 * 1024
    }] }, metadata: { _total: 1 } });
  };
  const id = cloudPanTestSupport.encodePayload({
    provider: "quark",
    url: "https://pan.quark.cn/s/demo?pwd=A8c2",
    password: "",
    note: "示例剧",
    image: ""
  });
  const result = await handleCloudPanAction({
    action: "detail",
    argumentsValue: { ids: [id] },
    cloud: {},
    credentials: {},
    initializeCloud: async () => { initializations += 1; },
    fetchValue
  });

  assert.equal(result.list[0].vod_play_from, "夸克网盘-普画");
  assert.match(result.list[0].vod_play_url, /第一集\.mp4\$/);
  assert.match(result.list[0].vod_play_url, /正片\/第二集\.mkv\$/);
  assert.equal(result.list[0].vod_play_url.split("#").length, 2);
  assert.equal(initializations, 0);
  assert.equal(requests.length, 3);
});

test("Quark detail replaces an expired indexed share with a working same-title share", async () => {
  const requests = [];
  const fetchValue = async (url, options) => {
    const value = new URL(url);
    requests.push(value.href);
    if (value.hostname === "search.example") {
      return jsonResponse({ code: 0, data: { merged_by_type: {
        quark: [{
          url: "https://pan.quark.cn/s/working",
          password: "",
          note: "同名影片",
          images: []
        }],
        aliyun: [],
        123: []
      } } });
    }
    if (value.pathname.endsWith("/share/sharepage/token")) {
      const body = JSON.parse(options.body);
      if (body.pwd_id === "expired") return jsonResponse({}, 404);
      return jsonResponse({ code: 0, data: { stoken: "working-token" } });
    }
    if (value.pathname.endsWith("/share/sharepage/detail")) {
      assert.equal(value.searchParams.get("pwd_id"), "working");
      return jsonResponse({ code: 0, data: { list: [{
        file: true,
        fid: "working-video",
        share_fid_token: "working-file-token",
        file_name: "正片.mp4",
        obj_category: "video",
        size: 100 * 1024 * 1024
      }] }, metadata: { _total: 1 } });
    }
    throw new Error(`Unexpected request: ${value}`);
  };
  const id = cloudPanTestSupport.encodePayload({
    provider: "quark",
    url: "https://pan.quark.cn/s/expired",
    password: "",
    note: "同名影片",
    image: ""
  });
  const result = await handleCloudPanAction({
    action: "detail",
    argumentsValue: { ids: [id] },
    credentials: {},
    fetchValue,
    searchEndpoint: "https://search.example/api/search"
  });

  assert.equal(result.list[0].vod_name, "同名影片");
  assert.match(result.list[0].vod_play_url, /正片\.mp4\$/);
  assert.equal(requests.filter((url) => url.includes("/share/sharepage/token")).length, 2);
});

test("Quark player saves into an account-specific cache and selects the highest available quality", async () => {
  const cookie = "__puus=session; kps=login";
  const requests = [];
  const fetchValue = async (url, options) => {
    const value = new URL(url);
    const body = options.body ? JSON.parse(options.body) : undefined;
    requests.push({ url: value, body, headers: options.headers });
    if (value.pathname.endsWith("/file/sort") && value.searchParams.get("pdir_fid") === "0") {
      return jsonResponse({ code: 0, data: { list: [] } });
    }
    if (value.pathname.endsWith("/file")) {
      assert.equal(body.file_name, cloudPanTestSupport.quarkCacheDirectoryName(cookie));
      return jsonResponse({ code: 0, data: { fid: "cache-directory" } });
    }
    if (value.pathname.endsWith("/file/sort")) {
      return jsonResponse({ code: 0, data: { list: [] } });
    }
    if (value.pathname.endsWith("/share/sharepage/save")) {
      assert.deepEqual(body.fid_list, ["shared-file"]);
      assert.deepEqual(body.fid_token_list, ["shared-file-token"]);
      return jsonResponse({ code: 0, data: { task_id: "save-task" } });
    }
    if (value.pathname.endsWith("/task")) {
      return jsonResponse({ code: 0, data: { save_as: { save_as_top_fids: ["saved-file"] } } });
    }
    if (value.pathname.endsWith("/file/v2/play")) {
      assert.equal(body.fid, "saved-file");
      return jsonResponse({ code: 0, data: { video_list: [
        { resolution: "high", video_info: { url: "https://video.quark.example/high.mp4" } },
        { resolution: "low", video_info: { url: "https://video.quark.example/low.mp4" } },
        { resolution: "4k", video_info: { url: "https://video.quark.example/4k.mp4" } },
        { resolution: "2k", video_info: { url: "https://video.quark.example/2k.mp4" } }
      ] } });
    }
    throw new Error(`Unexpected Quark request: ${value}`);
  };
  const episodeID = cloudPanTestSupport.encodePayload({
    provider: "quark",
    shareId: "demo",
    stoken: "share-token",
    fileId: "shared-file",
    fileToken: "shared-file-token"
  });
  const result = await handleCloudPanAction({
    action: "player",
    argumentsValue: { flag: "夸克网盘-普画", id: episodeID, vipFlags: [] },
    cloud: {},
    credentials: { quarkCookie: cookie },
    fetchValue
  });

  assert.equal(result.url, "https://video.quark.example/4k.mp4");
  assert.deepEqual(result.qualityOptions, [
    { name: "4K", url: "https://video.quark.example/4k.mp4" },
    { name: "2K", url: "https://video.quark.example/2k.mp4" },
    { name: "高清", url: "https://video.quark.example/high.mp4" },
    { name: "流畅", url: "https://video.quark.example/low.mp4" }
  ]);
  assert.equal(result.parse, 0);
  assert.equal(result.header.cookie, undefined);
  assert.equal(result.header.referer, "https://pan.quark.cn/");
  assert.equal(requests.length, 6);
});

test("Quark playback only sends account cookies to Quark domains", () => {
  const cookie = "__puus=session; kps=login";
  assert.equal(
    cloudPanTestSupport.quarkPlaybackHeaders("https://video.quark.cn/movie.mp4", cookie).cookie,
    cookie
  );
  assert.equal(
    cloudPanTestSupport.quarkPlaybackHeaders("https://signed.cdn.example/movie.mp4", cookie).cookie,
    undefined
  );
});

test("Quark player reports a clear login requirement before making requests", async () => {
  let requests = 0;
  const episodeID = cloudPanTestSupport.encodePayload({
    provider: "quark",
    shareId: "demo",
    stoken: "share-token",
    fileId: "shared-file",
    fileToken: "shared-file-token"
  });
  await assert.rejects(
    handleCloudPanAction({
      action: "player",
      argumentsValue: { flag: "夸克网盘-普画", id: episodeID },
      credentials: {},
      fetchValue: async () => { requests += 1; }
    }),
    /设置 → 网盘账号/
  );
  assert.equal(requests, 0);
});

test("cloud search normalizes and de-duplicates supported providers", async () => {
  const fetchValue = async () => ({
    ok: true,
    json: async () => ({ code: 0, data: { merged_by_type: {
      quark: [
        { url: "https://pan.quark.cn/s/demo", note: "示例电影", images: ["https://img.example/poster.jpg"] },
        { url: "https://pan.quark.cn/s/demo", note: "重复结果" }
      ],
      aliyun: [],
      123: [{ url: "https://123pan.com/s/demo?提取码=ABCD", password: "ABCD", note: "123 示例" }]
    } } })
  });
  const values = await searchCloudResources("示例", fetchValue);
  assert.equal(values.length, 2);
  assert.equal(values[0].vod_remarks, "夸克网盘");
  assert.equal(cloudPanTestSupport.decodePayload(values[1].vod_id).password, "ABCD");
});

test("123 web API signing is deterministic and includes its dynamic signature", () => {
  const url = cloudPanTestSupport.signed123URL(
    "https://yun.123pan.com/b/api/share/get",
    new Date("2026-07-19T00:00:00Z"),
    0.5
  );
  assert.equal(url.pathname, "/b/api/share/get");
  assert.equal([...url.searchParams].length, 1);
  assert.match([...url.searchParams.values()][0], /^1784419200-5000000-\d+$/);
});

test("CatVod actions use the qist request field names", () => {
  const site = { api: "/spider/demo/3" };
  assert.deepEqual(
    actionRequest(site, "category", { tid: "movie", page: "2", filter: true, extend: { area: "CN" } }),
    { path: "/spider/demo/3/category", payload: { id: "movie", page: "2", filter: true, filters: { area: "CN" } } }
  );
  assert.deepEqual(
    actionRequest(site, "search", { keyword: "demo", quick: false, page: "3" }),
    { path: "/spider/demo/3/search", payload: { wd: "demo", quick: false, page: "3" } }
  );
});

test("CatVod runner only inherits non-credentialed proxy URLs", () => {
  assert.deepEqual(safeProxyEnvironment({
    HTTP_PROXY: "http://127.0.0.1:7897",
    HTTPS_PROXY: "https://user:secret@example.com:443",
    ALL_PROXY: "not-a-url"
  }), { HTTP_PROXY: "http://127.0.0.1:7897/" });
});

test("CatVod enables the Node 26 network permission when available", () => {
  assert.deepEqual(catVodPermissionArguments(new Set(["--allow-net"])), ["--permission", "--allow-net"]);
  assert.deepEqual(catVodPermissionArguments(new Set()), ["--permission"]);
});

test("CatVod file permissions allow relative database access only inside its runtime cwd", () => {
  const permissions = catVodFilePermissionArguments("/cache/bundle.js", "/cache/runtime/session");
  assert.ok(permissions.includes("--allow-fs-read=."));
  assert.ok(permissions.includes("--allow-fs-write=."));
  assert.ok(permissions.includes("--allow-fs-read=/cache/bundle.js"));
  assert.ok(permissions.includes("--allow-fs-write=/cache/runtime/session"));
  assert.ok(!permissions.includes("--allow-fs-read=/"));
  assert.ok(!permissions.includes("--allow-fs-write=/"));
});

test("CatVod player preserves direct episode URLs when a provider returns an empty URL", () => {
  assert.deepEqual(
    normalizePlayerResult({ parse: 0, url: "", jx: "0" }, "https://media.example/live.m3u8"),
    { parse: 0, url: "https://media.example/live.m3u8", jx: 0 }
  );
  assert.equal(normalizePlayerResult({ url: "" }, "local-id").url, "");
});

test("CatVod player resolves xb6v nested playback pages to HLS", async () => {
  const requests = [];
  const fetchValue = async (url) => {
    requests.push(url.href);
    if (requests.length === 1) {
      return { ok: true, text: async () => '<iframe src="https://player.example/share/demo"></iframe>' };
    }
    return { ok: true, text: async () => '<script>const url = "/media/demo/index.m3u8?sign=test";</script>' };
  };

  const result = await resolvePlayerResult(
    { api: "/spider/xb6v/3", ext: "https://www.xb6v.com/" },
    { url: "https://player.example/share/demo/index.m3u8", header: { Referer: "demo" } },
    "/e/DownSys/play/?id=1",
    fetchValue
  );

  assert.deepEqual(requests, [
    "https://www.xb6v.com/e/DownSys/play/?id=1",
    "https://player.example/share/demo"
  ]);
  assert.deepEqual(result, {
    parse: 0,
    jx: 0,
    url: "https://player.example/media/demo/index.m3u8?sign=test",
    header: { Referer: "demo" }
  });
});

test("JarCache downloads, verifies and reuses a JAR", async (t) => {
  let downloads = 0;
  const jarServer = http.createServer((_request, response) => {
    downloads += 1;
    response.writeHead(200, { "content-type": "application/java-archive", "content-length": fakeJar.length });
    response.end(fakeJar);
  });
  const jarBaseURL = await listen(jarServer);
  const directory = await mkdtemp(path.join(os.tmpdir(), "spider-jar-test-"));
  t.after(async () => {
    await new Promise((resolve) => jarServer.close(resolve));
    await rm(directory, { recursive: true, force: true });
  });
  const cache = new JarCache(baseConfig({ cacheDir: directory }));
  const md5 = createHash("md5").update(fakeJar).digest("hex");
  const first = await cache.resolve(`${jarBaseURL}/spider.jar;md5;${md5}`);
  const second = await cache.resolve(`${jarBaseURL}/spider.jar;md5;${md5}`);
  assert.equal(first.path, second.path);
  assert.equal(downloads, 1);
});

test("Gateway executes requests through a persistent worker session", async (t) => {
  const jarServer = http.createServer((_request, response) => response.end(fakeJar));
  const jarBaseURL = await listen(jarServer);
  const directory = await mkdtemp(path.join(os.tmpdir(), "spider-gateway-test-"));
  const config = baseConfig({ cacheDir: directory });
  const gateway = createGateway(config);
  const address = await gateway.listen();
  const baseURL = `http://127.0.0.1:${address.port}`;
  t.after(async () => {
    await gateway.close();
    await new Promise((resolve) => jarServer.close(resolve));
    await rm(directory, { recursive: true, force: true });
  });

  const health = await fetch(`${baseURL}/health`).then((response) => response.json());
  assert.deepEqual(health, { status: "ok", protocol: 1, workerConfigured: true, catVodConfigured: true });

  const home = await post(`${baseURL}/v1/spider/invoke`, request(`${jarBaseURL}/spider.jar`));
  assert.equal(home.status, 200);
  assert.equal(home.body.list[0].vod_id, "home-1");
  assert.equal(home.body.workerInvocation, 1);

  const player = await post(`${baseURL}/v1/spider/invoke`, request(
    `${jarBaseURL}/spider.jar`,
    "player",
    { flag: "直连", id: "episode-1", vipFlags: [] }
  ));
  assert.equal(player.status, 200);
  assert.equal(player.body.url, "https://media.example/episode-1.m3u8");
  assert.equal(player.body.workerInvocation, 2);
});

test("Gateway exposes CatVod catalogs and routes Node sources without a JAR worker", async (t) => {
  const artifact = { path: "/fixture/index.js", digest: "fixture", sourceURL: "https://example.test/index.js" };
  const calls = [];
  const dependencies = {
    jarCache: { resolve: async () => { throw new Error("JAR path must not be used"); } },
    workers: { invoke: async () => { throw new Error("Worker must not be used"); }, close() {} },
    nodeBundleCache: { resolve: async (bundle) => { calls.push(["resolve", bundle]); return artifact; } },
    catVod: {
      catalog: async () => ({ sites: [{ key: "nodejs_demo", name: "Demo", api: "/spider/demo/3", type: 4 }] }),
      invoke: async (_artifact, _site, action) => ({ list: [{ vod_id: `${action}-1` }] }),
      close() {}
    }
  };
  const gateway = createGateway(baseConfig(), dependencies);
  const address = await gateway.listen();
  const baseURL = `http://127.0.0.1:${address.port}`;
  t.after(() => gateway.close());

  const bundle = "https://raw.githubusercontent.com/qist/tvbox/master/cat/dist/index.js.md5";
  const catalog = await post(`${baseURL}/v1/catvod/catalog`, { bundle });
  assert.equal(catalog.status, 200);
  assert.equal(catalog.body.sites[0].jar, bundle);
  assert.equal(catalog.body.sites[0].type, 3);

  const nodeRequest = request(bundle);
  nodeRequest.site.api = "/spider/demo/3";
  const home = await post(`${baseURL}/v1/spider/invoke`, nodeRequest);
  assert.equal(home.status, 200);
  assert.equal(home.body.list[0].vod_id, "home-1");
  assert.equal(calls.length, 2);
});

test("Gateway rejects unauthorized and malformed requests", async (t) => {
  const config = baseConfig({ cacheDir: await mkdtemp(path.join(os.tmpdir(), "spider-auth-test-")) });
  const gateway = createGateway(config);
  const address = await gateway.listen();
  const url = `http://127.0.0.1:${address.port}/v1/spider/invoke`;
  t.after(async () => {
    await gateway.close();
    await rm(config.cacheDir, { recursive: true, force: true });
  });

  const unauthorized = await post(url, request("https://example.com/spider.jar"), "wrong");
  assert.equal(unauthorized.status, 401);
  assert.equal(unauthorized.body.code, "UNAUTHORIZED");

  const malformed = await post(url, { version: 1, action: "home", site: {}, arguments: {} });
  assert.equal(malformed.status, 400);
  assert.equal(malformed.body.code, "INVALID_REQUEST");

  const unsafeRoute = request("https://example.com/index.js");
  unsafeRoute.site.api = "/spider/demo/3/../../config";
  const unsafe = await post(url, unsafeRoute);
  assert.equal(unsafe.status, 400);
  assert.equal(unsafe.body.code, "UNSUPPORTED_API");
});
