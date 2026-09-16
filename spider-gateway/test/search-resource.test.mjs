import test from "node:test";
import assert from "node:assert/strict";
import { handlePanSearchAction } from "../src/pan-search.mjs";

test("search to detail preserves the extraction code of a valid Funletu share", async () => {
  const site = { api: "/spider/pansearch/3", ext: '{"engine":"funletu"}' };
  const fetchValue = async (url, options) => {
    if (String(url).includes("v.funletu.com")) {
      return Response.json({ data: [{
        valid: 0, title: "测试剧", url: "https://pan.quark.cn/s/demo?pwd=abcd&entry=funletu"
      }] });
    }
    if (String(url).includes("sharepage/token")) {
      const { passcode } = JSON.parse(options.body);
      return Response.json({ data: passcode === "abcd" ? { stoken: "test-token" } : {} });
    }
    if (String(url).includes("sharepage/detail")) {
      return Response.json({ data: { list: [{
        fid: "test-file", file_name: "第1集.mp4", size: 10 * 1024 * 1024
      }] } });
    }
    throw new Error("Unexpected request in local fixture");
  };
  const search = await handlePanSearchAction({
    action: "search", site, argumentsValue: { keyword: "测试剧" }, fetchValue
  });
  assert.equal(search.list.length, 1);
  const detail = await handlePanSearchAction({
    action: "detail", site, argumentsValue: { ids: [search.list[0].vod_id] }, fetchValue
  });
  assert.match(detail.list[0].vod_play_url, /第1集/);
});

test("resource verification reports the selected expired share without searching for a substitute", async () => {
  const id = Buffer.from(JSON.stringify({
    provider: "quark", url: "https://pan.quark.cn/s/expired", note: "测试剧"
  })).toString("base64url");
  let requests = 0;
  await assert.rejects(handlePanSearchAction({
    action: "detail",
    argumentsValue: { ids: [id], verifyResource: true },
    fetchValue: async () => {
      requests += 1;
      return Response.json({}, { status: 404 });
    }
  }), /HTTP 404/);
  assert.equal(requests, 1);
});
