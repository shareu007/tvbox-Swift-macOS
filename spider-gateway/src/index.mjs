import { loadConfig } from "./config.mjs";
import { startParentWatchdog } from "./process-lifecycle.mjs";
import { readBoundedJSONObject } from "./secure-config.mjs";
import { createGateway } from "./server.mjs";

const bootstrap = process.env.TVBOX_GATEWAY_BOOTSTRAP_STDIN === "1"
  ? await readBoundedJSONObject(process.stdin, undefined, "Gateway bootstrap")
  : {};
delete process.env.TVBOX_GATEWAY_BOOTSTRAP_STDIN;
const config = loadConfig(bootstrap);
const gateway = createGateway(config);
const address = await gateway.listen();
const host = typeof address === "object" && address ? address.address : config.host;
const port = typeof address === "object" && address ? address.port : config.port;
console.log(`Spider Gateway listening on http://${host}:${port}`);
if (!config.workerCommand) console.warn("SPIDER_WORKER_COMMAND is not configured; csp_* JAR requests will return WORKER_UNAVAILABLE (CatVod Node sources remain available)");

let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  await gateway.close();
}

startParentWatchdog(stop);

process.once("SIGINT", () => stop().finally(() => process.exit(0)));
process.once("SIGTERM", () => stop().finally(() => process.exit(0)));
