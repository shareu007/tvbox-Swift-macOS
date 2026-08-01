# Spider Gateway

这是 TVBox Swift 的 `type=3 (JAR/Spider)` 服务端入口。它支持两条互不依赖的执行路径：

- CatVod Node bundle（如 qist/tvbox 的 `cat/dist/index.js`）：直接在 macOS 的受限 Node 子进程执行，**不需要 Android**。
- `csp_*` JAR：仅这类 Android Spider JAR 需要另外配置 Android Worker。

Gateway 不会在 macOS 进程中解释 Android DEX。TVBox Spider JAR 依赖 Android `Context` 和 `DexClassLoader`，必须由实现下述协议的 Android Worker 执行；不想安装 Android 环境时可以只使用 CatVod Node 源。

## 本机启动

要求 Node.js 22.13 或更高版本，不需要安装 npm 依赖。

```bash
cd spider-gateway
SPIDER_GATEWAY_TOKEN=change-me \
npm start
```

默认监听 `127.0.0.1:8787`。检查状态：

```bash
curl http://127.0.0.1:8787/health
```

没有配置 `SPIDER_WORKER_COMMAND` 时 CatVod Node 源仍可正常使用，只有 `csp_*` JAR 调用会返回 `WORKER_UNAVAILABLE`。

在 App 设置里填写本机 Gateway 地址 `http://127.0.0.1:8787`（如设置了 Token 也一并填写），然后把下面的 bundle 地址作为点播接口导入：

```text
https://raw.githubusercontent.com/qist/tvbox/master/cat/dist/index.js.md5
```

App 会通过 `/v1/catvod/catalog` 读取 bundle 暴露的视频站点，再把首页、分类、详情、搜索和播放请求转到对应的 `/spider/...` 接口。

## 主要配置

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SPIDER_GATEWAY_HOST` | `127.0.0.1` | 监听地址 |
| `SPIDER_GATEWAY_PORT` | `8787` | 监听端口 |
| `SPIDER_GATEWAY_TOKEN` | 空 | Bearer Token；对外部署必须设置 |
| `SPIDER_GATEWAY_CACHE_DIR` | `spider-gateway/data/jars` | JAR 缓存目录 |
| `CATVOD_BUNDLE_CACHE_DIR` | `spider-gateway/data/bundles` | CatVod bundle 缓存目录 |
| `CATVOD_BUNDLE_ALLOWED_URLS` | qist 的 `.js` 与 `.js.md5` 地址 | 允许执行的 bundle URL，逗号分隔、精确匹配 |
| `CATVOD_BUNDLE_ALLOW_HTTP` | `false` | 允许白名单内的精确 bundle 使用 HTTP；认证信息可能明文传输，应优先使用 HTTPS |
| `CATVOD_BUNDLE_ALLOW_PRIVATE_NETWORK` | `false` | 允许从本机或私网下载 bundle；仅用于可信本地测试 |
| `CATVOD_BUNDLE_MAX_BYTES` | `16777216` | 单个 Node bundle 最大字节数 |
| `CATVOD_RUNTIME_DIR` | `spider-gateway/data/runtime` | bundle 独立运行数据目录 |
| `SPIDER_JAR_ALLOWED_HOSTS` | 空 | 逗号分隔域名白名单，支持 `*.example.com` |
| `SPIDER_JAR_ALLOW_PRIVATE_NETWORK` | `false` | 是否允许从私网下载 JAR；只建议本地测试开启 |
| `SPIDER_JAR_MAX_BYTES` | `67108864` | 单个 JAR 最大字节数 |
| `SPIDER_WORKER_COMMAND` | 空 | Android Worker 可执行命令 |
| `SPIDER_WORKER_ARGS` | `[]` | Worker 参数，JSON 字符串数组 |
| `SPIDER_WORKER_TIMEOUT_MS` | `20000` | 单次 Spider 调用超时 |
| `SPIDER_WORKER_MAX_SESSIONS` | `16` | 最大常驻站点会话数 |

JAR 地址支持 TVBox 后缀，例如 `https://example.com/spider.jar;md5;<32位摘要>`，也支持 `sha256`。默认阻止本机、私网和云元数据网段，重定向后的目标也会重新检查。

CatVod bundle 属于远程代码，只允许 `CATVOD_BUNDLE_ALLOWED_URLS` 中精确列出的地址。内置 macOS Gateway 会在用户主动填写 CatVod 配置时，只把当前 bundle 的脱敏 URL 加入该进程白名单；切换 bundle 会重启进程并替换白名单。每次下载及重定向都会重新检查 DNS 并阻止私网地址。URL 中的 Basic Auth 会转换为请求头，只发送给原始站点，同源重定向保留、跨域重定向丢弃。每个 bundle 在独立 Node 进程执行，并通过 Node Permission Model 仅开放 bundle、runner 和专属运行目录的文件访问；不开放子进程、Worker 或原生扩展权限。

Node 26 开始把网络访问也纳入 Permission Model，Gateway 会在运行时检测并为 CatVod 子进程增加 `--allow-net`。无凭据的 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 会传给子进程；包含用户名或密码的代理 URL 会被丢弃。

## Worker 协议

Gateway 为每个 `JAR 摘要 + site.key + api + ext` 启动一个长连接 Worker。stdin/stdout 使用一行一个 JSON 对象；Worker 不得把普通日志写到 stdout。

初始化请求：

```json
{"id":"uuid","type":"init","session":"...","jarPath":"/cache/hash.jar","jarDigest":"...","site":{"key":"demo","api":"csp_Demo","jar":"...","ext":"","quickSearch":true}}
```

调用请求：

```json
{"id":"uuid","type":"invoke","action":"home","arguments":{"filter":true}}
```

成功和失败响应：

```json
{"id":"uuid","ok":true,"result":{"class":[],"list":[]}}
{"id":"uuid","ok":false,"code":"SPIDER_ERROR","message":"Spider execution failed"}
```

Android Worker 应用 `DexClassLoader` 加载 `com.github.catvod.spider.<api 去掉 csp_>`，在初始化时调用 `init(context, ext)`，并映射 `homeContent/homeVideoContent/categoryContent/detailContent/searchContent/playerContent`。`home` 需要合并首页两个方法的 JSON；退出或会话淘汰时调用 `destroy()`。

## 验证

```bash
cd spider-gateway
npm test
```

测试覆盖 JAR 下载校验与缓存、鉴权、健康检查、会话复用、CatVod bundle 改写、目录发现与 Node/JAR 路由分流。
