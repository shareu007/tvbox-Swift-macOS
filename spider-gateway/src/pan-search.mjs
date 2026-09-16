import {
  createCloudSearchResult,
  handleCloudPanAction,
  searchCloudResources
} from "./cloud-pan.mjs";
import { readBoundedJSON, readBoundedText } from "./bounded-response.mjs";

const PAN_SEARCH_API = "/spider/pansearch/3";
const KUAFU_SEARCH_ENDPOINT = "https://www.melost.cn/search";
const FUNLETU_SEARCH_ENDPOINT = "https://v.funletu.com/search";
const YYETS_SEARCH_ENDPOINT = "https://yyets.click/api/resource";
const KKPANS_SEARCH_ENDPOINT = "https://www.kkpans.com/api/resources/public";
const USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124 Safari/537.36";

export function isPanSearchSite(site) {
  return site?.api === PAN_SEARCH_API;
}

function decodeHTML(value) {
  return String(value || "")
    .replace(/<[^>]*>/g, "")
    .replaceAll("&amp;", "&")
    .replaceAll("&quot;", "\"")
    .replaceAll("&#39;", "'")
    .replaceAll("&lt;", "<")
    .replaceAll("&gt;", ">")
    .replace(/&#(\d+);/g, (_, code) => String.fromCodePoint(Number(code)))
    .replace(/\s+/g, " ")
    .trim();
}

function attribute(tag, name) {
  const match = tag.match(new RegExp(`\\b${name}\\s*=\\s*(["'])(.*?)\\1`, "is"));
  return match ? decodeHTML(match[2]) : "";
}

function providerForURL(rawURL) {
  try {
    const hostname = new URL(rawURL).hostname.toLowerCase();
    if (hostname === "pan.quark.cn") return "quark";
    if (hostname === "www.aliyundrive.com" || hostname === "www.alipan.com") return "aliyun";
    if (["123pan.com", "www.123pan.com", "123684.com", "www.123684.com", "123865.com", "www.123865.com"].includes(hostname)) {
      return "123";
    }
  } catch {
    // Ignore malformed third-party result URLs.
  }
  return "";
}

function pushCloudResult(values, seen, rawURL, note, password = "") {
  const provider = providerForURL(rawURL);
  if (!provider) return;
  try {
    const item = createCloudSearchResult(provider, {
      url: rawURL,
      note,
      password,
      images: []
    });
    const key = `${provider}\0${String(rawURL).trim()}`;
    if (seen.has(key)) return;
    seen.add(key);
    values.push(item);
  } catch {
    // A malformed third-party result must not fail the whole search.
  }
}

export function parseKuafuSearchHTML(html) {
  const values = [];
  const seen = new Set();
  const anchorPattern = /<a\b[^>]*\bclass\s*=\s*(["'])[^"']*\bsearch-item-title\b[^"']*\1[^>]*>[\s\S]*?<\/a>/gi;
  for (const match of String(html || "").matchAll(anchorPattern)) {
    const tag = match[0].match(/^<a\b[^>]*>/i)?.[0] || "";
    const url = attribute(tag, "href");
    const provider = providerForURL(url);
    if (!provider || seen.has(url)) continue;
    seen.add(url);
    const title = attribute(tag, "title") || decodeHTML(match[0]);
    try {
      values.push(createCloudSearchResult(provider, {
        url,
        note: title,
        password: "",
        images: []
      }));
    } catch {
      // A single malformed search result must not fail the entire source.
    }
  }
  return values.slice(0, 80);
}

export async function searchKuafuResources(keyword, fetchValue = fetch, endpoint = KUAFU_SEARCH_ENDPOINT) {
  const query = String(keyword || "").trim();
  if (!query) return [];
  const url = new URL(endpoint);
  url.searchParams.set("exact", "false");
  url.searchParams.set("format", "video");
  url.searchParams.set("page", "1");
  url.searchParams.set("q", query);
  const response = await fetchValue(url, {
    headers: {
      accept: "text/html,application/xhtml+xml",
      "user-agent": USER_AGENT
    }
  });
  if (!response.ok) throw new Error(`夸父盘搜返回 HTTP ${response.status}`);
  return parseKuafuSearchHTML(await readBoundedText(response));
}

export function parseFunletuSearchJSON(body) {
  const rows = Array.isArray(body?.data) ? body.data : [];
  const values = [];
  const seen = new Set();
  for (const row of rows) {
    if (row?.valid !== undefined && Number(row.valid) !== 0) continue;
    // Tracking parameters can be discarded, but pwd is required to open protected shares.
    let rawURL = String(row?.url || "");
    try {
      const url = new URL(rawURL);
      url.searchParams.delete("entry");
      rawURL = url.toString();
    } catch { /* Malformed entries are ignored by pushCloudResult. */ }
    const note = row?.title || row?.filename || row?.name || row?.updatetime || "趣盘搜资源";
    pushCloudResult(values, seen, rawURL, note, row?.password || row?.share_code || "");
  }
  return values.slice(0, 80);
}

export async function searchFunletuResources(keyword, fetchValue = fetch, endpoint = FUNLETU_SEARCH_ENDPOINT) {
  const query = String(keyword || "").trim();
  if (!query) return [];
  const response = await fetchValue(endpoint, {
    method: "POST",
    headers: {
      accept: "application/json",
      "content-type": "application/json",
      referer: "https://pan.funletu.com/",
      "user-agent": USER_AGENT
    },
    body: JSON.stringify({
      style: "get",
      datasrc: "search",
      query: {
        id: "",
        datetime: "",
        commonid: 1,
        parmid: "",
        fileid: "",
        reportid: "",
        validid: "",
        searchtext: query
      },
      page: { pageSize: 20, pageIndex: 1 },
      order: { prop: "id", order: "desc" },
      message: "请求资源列表数据"
    })
  });
  if (!response.ok) throw new Error(`趣盘搜返回 HTTP ${response.status}`);
  let body;
  try {
    body = await readBoundedJSON(response);
  } catch {
    throw new Error("趣盘搜返回了无效数据");
  }
  return parseFunletuSearchJSON(body);
}

function cloudURLs(text) {
  return String(text || "").match(/https?:\/\/[^\s"'<>，。]+/giu) || [];
}

function yyetsTitle(comment, rawURL, keyword) {
  const lines = String(comment || "").split(/\r?\n/);
  const lineIndex = lines.findIndex((line) => line.includes(rawURL));
  const inline = (lineIndex >= 0 ? lines[lineIndex] : "")
    .replace(rawURL, "")
    .replace(/^(?:链接|地址)\s*[:：]?\s*/u, "")
    .replace(/[「」《》]/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (inline) return inline;
  for (let index = lineIndex - 1; index >= 0; index -= 1) {
    const candidate = lines[index]
      .replace(/[「」《》]/gu, " ")
      .replace(/\s+/g, " ")
      .trim();
    if (candidate && !candidate.startsWith("http")) return candidate;
  }
  return String(keyword || "").trim() || "人人影视网盘资源";
}

export function parseYYetsSearchJSON(body, keyword) {
  const comments = Array.isArray(body?.comment) ? body.comment : [];
  const values = [];
  const seen = new Set();
  for (const row of comments) {
    const comment = String(row?.comment || "");
    for (const rawURL of cloudURLs(comment)) {
      pushCloudResult(values, seen, rawURL, yyetsTitle(comment, rawURL, keyword));
    }
  }
  return values.slice(0, 80);
}

export async function searchYYetsResources(keyword, fetchValue = fetch, endpoint = YYETS_SEARCH_ENDPOINT) {
  const query = String(keyword || "").trim();
  if (!query) return [];
  const url = new URL(endpoint);
  url.searchParams.set("keyword", query);
  url.searchParams.set("type", "default");
  const response = await fetchValue(url, {
    headers: {
      accept: "application/json",
      referer: `https://yyets.click/search?keyword=${encodeURIComponent(query)}&type=default`,
      "user-agent": USER_AGENT
    }
  });
  if (!response.ok) throw new Error(`人人影视搜返回 HTTP ${response.status}`);
  let body;
  try {
    body = await readBoundedJSON(response);
  } catch {
    throw new Error("人人影视搜返回了无效数据");
  }
  return parseYYetsSearchJSON(body, query);
}

export function parseKKPansSearchJSON(body) {
  const rows = Array.isArray(body?.data) ? body.data : [];
  const values = [];
  const seen = new Set();
  for (const row of rows) {
    const declaredProvider = String(row?.target_platform || "").trim().toLowerCase();
    if (declaredProvider && declaredProvider !== "quark") continue;
    const candidates = [row?.share_link, row?.original_url]
      .map((value) => String(value || "").trim())
      .filter(Boolean);
    const rawURL = candidates.find((value) => providerForURL(value) === "quark") || "";
    if (!rawURL) continue;
    const note = row?.file_name || row?.title || row?.name || "KK网盘夸克资源";
    pushCloudResult(values, seen, rawURL, note, row?.share_code || "");
  }
  return values.slice(0, 80);
}

export async function searchKKPansResources(
  keyword,
  fetchValue = fetch,
  endpoint = KKPANS_SEARCH_ENDPOINT,
  requestedPage = 1
) {
  const query = String(keyword || "").trim();
  if (!query) return [];
  const page = Math.max(1, Number.parseInt(requestedPage, 10) || 1);
  const url = new URL(endpoint);
  url.searchParams.set("page", String(page));
  url.searchParams.set("limit", "20");
  url.searchParams.set("search", query);
  url.searchParams.set("platform", "quark");
  url.searchParams.set("sort", "featured");
  const response = await fetchValue(url, {
    headers: {
      accept: "application/json",
      referer: "https://www.kkpans.com/",
      "user-agent": USER_AGENT
    }
  });
  if (!response.ok) throw new Error(`KK网盘返回 HTTP ${response.status}`);
  let body;
  try {
    body = await readBoundedJSON(response);
  } catch {
    throw new Error("KK网盘返回了无效数据");
  }
  return parseKKPansSearchJSON(body);
}

export function parseQuarkShareCatalog(text, keyword) {
  const query = String(keyword || "").trim().toLocaleLowerCase();
  const values = [];
  const seen = new Set();
  for (const rawLine of String(text || "").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#") || line.startsWith("//")) continue;
    const match = line.match(/^(\S+)(?:\s+(.+))?$/u);
    if (!match || match[1].toLowerCase() === "self") continue;
    const token = match[1];
    const note = String(match[2] || "夸克分享").trim();
    if (query && !note.toLocaleLowerCase().includes(query)) continue;
    const rawURL = /^https?:\/\//iu.test(token)
      ? token
      : /^[A-Za-z0-9_-]{8,}$/u.test(token)
        ? `https://pan.quark.cn/s/${token}`
        : "";
    pushCloudResult(values, seen, rawURL, note);
  }
  return values.slice(0, 80);
}

export async function searchQuarkShareCatalog(keyword, fetchValue = fetch, listURL) {
  let url;
  try {
    url = new URL(String(listURL || ""));
  } catch {
    throw new Error("夸克分享清单地址无效");
  }
  if (!["http:", "https:"].includes(url.protocol)) {
    throw new Error("夸克分享清单必须使用 HTTP 或 HTTPS 地址");
  }
  const response = await fetchValue(url, {
    headers: {
      accept: "text/plain,*/*",
      "user-agent": USER_AGENT
    }
  });
  if (!response.ok) throw new Error(`夸克分享清单返回 HTTP ${response.status}`);
  return parseQuarkShareCatalog(await readBoundedText(response), keyword);
}

function extension(site) {
  try {
    return JSON.parse(site?.ext || "{}");
  } catch {
    return {};
  }
}

function panSouEndpoint(ext) {
  const siteURL = String(ext.siteUrl || "").trim();
  if (!siteURL) return undefined;
  try {
    return new URL("/api/search", siteURL).toString();
  } catch {
    return undefined;
  }
}

export async function handlePanSearchAction(options) {
  const { action, argumentsValue, fetchValue = fetch, site } = options;
  if (action !== "search") return handleCloudPanAction(options);
  const ext = extension(site);
  if (ext.engine === "kuafu") {
    return { list: await searchKuafuResources(argumentsValue.keyword, fetchValue) };
  }
  if (ext.engine === "pansou") {
    return {
      list: await searchCloudResources(
        argumentsValue.keyword,
        fetchValue,
        panSouEndpoint(ext)
      )
    };
  }
  if (ext.engine === "funletu") {
    return { list: await searchFunletuResources(argumentsValue.keyword, fetchValue) };
  }
  if (ext.engine === "yyets") {
    return { list: await searchYYetsResources(argumentsValue.keyword, fetchValue) };
  }
  if (ext.engine === "kkpans") {
    return {
      list: await searchKKPansResources(
        argumentsValue.keyword,
        fetchValue,
        undefined,
        argumentsValue.page
      )
    };
  }
  if (ext.engine === "quarkshare") {
    return {
      list: await searchQuarkShareCatalog(
        argumentsValue.keyword,
        fetchValue,
        ext.listURL
      )
    };
  }
  throw new Error("不支持的内置盘搜引擎");
}

export const panSearchTestSupport = {
  providerForURL
};
