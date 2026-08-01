import readline from "node:readline";

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
let site;
let invocationCount = 0;

function reply(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

input.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.type === "init") {
    site = message.site;
    reply({ id: message.id, ok: true });
    return;
  }
  if (message.type !== "invoke" || !site) {
    reply({ id: message.id, ok: false, code: "NOT_INITIALIZED", message: "Worker is not initialized" });
    return;
  }

  invocationCount += 1;
  const id = message.arguments.id || message.arguments.keyword || message.arguments.tid || "home";
  const common = { workerInvocation: invocationCount, siteKey: site.key };
  switch (message.action) {
    case "home":
      reply({ id: message.id, ok: true, result: {
        class: [{ type_id: "movie", type_name: "电影" }],
        list: [{ vod_id: "home-1", vod_name: "首页影片" }],
        ...common
      } });
      break;
    case "category":
    case "search":
      reply({ id: message.id, ok: true, result: {
        list: [{ vod_id: id, vod_name: `结果-${id}` }], page: 1, pagecount: 1, ...common
      } });
      break;
    case "detail":
      reply({ id: message.id, ok: true, result: {
        list: [{ vod_id: message.arguments.ids[0], vod_name: "详情", vod_play_from: "直连", vod_play_url: "第一集$episode-1" }],
        ...common
      } });
      break;
    case "player":
      reply({ id: message.id, ok: true, result: {
        parse: 0,
        url: `https://media.example/${encodeURIComponent(message.arguments.id)}.m3u8`,
        header: { Referer: "https://media.example/" },
        ...common
      } });
      break;
    default:
      reply({ id: message.id, ok: false, code: "UNSUPPORTED_ACTION", message: "Unsupported action" });
  }
});
