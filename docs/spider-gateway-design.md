# Type 3 Spider Gateway 设计

## 1. 决策

TVBox Swift 通过 Spider Gateway 支持两类 `type=3` 源：`csp_*` JAR 由可选 Android Worker 执行，CatVod Node bundle 的 `/spider/...` 接口由 macOS 本机的受限 Node 子进程执行。App 进程不下载或执行 JAR/DEX 或远程脚本。

该设计同时服务 iOS 和 macOS，并保持现有 `type=0/1/4` 数据源行为不变。

## 2. 首版范围

首版支持：

- 顶层 `spider` 作为站点默认 JAR。
- 站点级 `jar` 覆盖顶层 `spider`。
- 字符串或 JSON 类型的 `ext` 原样传给 Gateway。
- `csp_*` Spider 的 `homeContent`、`homeVideoContent`、`categoryContent`、`detailContent`、`searchContent` 和 `playerContent`。
- CatVod Node bundle 的目录发现，以及 `/home`、`/category`、`/detail`、`/search`、`/play` 映射。
- Gateway URL 由用户在设置中配置。
- Spider 返回的直连播放地址；播放请求头先进入统一播放上下文，播放器全链路透传安排在第二阶段。

首版不支持：

- 在 App 进程内执行 JAR、DEX、JavaScript 或 Python；macOS Gateway 可在隔离子进程执行允许列表中的 Node bundle。
- `proxy`、`action`、云盘扫码登录。
- `parse=1` / `jx=1` 的网页嗅探或第三方解析。
- DRM、字幕、弹幕的 Spider 扩展字段。
- `clan://`、`assets://` 等 Android 本地协议；Gateway 可以自行扩展这些协议。

## 3. 客户端结构

```text
SourceService
  |- CMS/Remote 路径（现有 type 0/1/4）
  `- SpiderGatewayService（type 3）
       `- NetworkManager
```

`SourceService` 保持 ViewModel 当前使用的入口，并根据 `SourceBean.type` 路由。Spider 的执行、会话、JAR 缓存和安全隔离都属于 Gateway 职责。

## 4. 配置规则

配置载入后，每个 type 3 站点应保留：

- `key`
- `name`
- `api`
- `jar = site.jar ?? config.spider`
- `ext`
- `searchable`
- `filterable`
- `quickSearch`
- `playerType`

`api` 可以是 `csp_ClassName` 或 CatVod 的 `/spider/<key>/<type>` 路径，不能统一按 HTTP URL 校验。只有 Gateway URL 和运行包地址需要是 HTTP/HTTPS URL。

## 5. Gateway API

### 5.1 请求

```http
POST {gatewayBaseURL}/v1/spider/invoke
Content-Type: application/json
```

```json
{
  "version": 1,
  "action": "category",
  "site": {
    "key": "demo",
    "api": "csp_Demo",
    "jar": "https://example.com/spider.jar",
    "ext": "{\"token\":\"...\"}",
    "quickSearch": true
  },
  "arguments": {
    "tid": "movie",
    "page": "1",
    "filter": true,
    "extend": {}
  }
}
```

字段说明：

- `version`：协议版本，当前固定为 `1`。
- `action`：`home`、`category`、`detail`、`search`、`player`。
- `site.jar`：已经应用站点覆盖规则的最终 JAR 地址；CatVod 源复用该字段传 bundle 地址。
- `site.ext`：字符串；配置中的对象/数组编码为 JSON 字符串。
- `arguments`：随 action 变化的参数对象。

action 参数：

| action | arguments |
| --- | --- |
| `home` | `filter: Bool` |
| `category` | `tid`, `page`, `filter`, `extend` |
| `detail` | `ids: [String]` |
| `search` | `keyword`, `quick`, `page` |
| `player` | `flag`, `id`, `vipFlags: [String]` |

### 5.2 成功响应

HTTP 2xx，响应体直接使用 Spider 标准 JSON，不再套 envelope。例如：

```json
{
  "class": [{"type_id":"movie","type_name":"电影"}],
  "list": [{"vod_id":"1","vod_name":"示例"}],
  "page": 1,
  "pagecount": 10
}
```

播放响应示例：

```json
{
  "parse": 0,
  "url": "https://media.example.com/video.m3u8",
  "header": {
    "User-Agent": "Example",
    "Referer": "https://example.com/"
  }
}
```

Gateway 应合并 `homeContent` 和 `homeVideoContent`：以 `homeContent` 的分类、筛选为主；当 `homeVideoContent` 返回非空 list 时，用它覆盖首页 list。

### 5.3 错误响应

HTTP 4xx/5xx：

```json
{
  "code": "SPIDER_TIMEOUT",
  "message": "Spider execution timed out"
}
```

客户端必须展示 `message`，但不得把 JAR 内容、服务端路径、调用栈或用户 token 写入日志。

## 6. Gateway 运行要求

- 每个 JAR 按规范化 URL 和校验值缓存。
- 每个站点实例按 `jar + site.key` 隔离，并在配置淘汰时调用 `destroy()`。
- JAR 在独立容器或进程中运行；设置 CPU、内存、磁盘和执行时间限制。
- 默认阻止访问 Gateway 本机、云元数据地址和私有网段，避免 SSRF。
- 日志过滤 `ext`、Cookie、Authorization 和查询参数中的凭证。
- 对客户端鉴权、限流，并限制可加载的 JAR 域名或签名。
- `player` 和后续 `proxy` 请求必须复用对应 Spider 会话。
- 远程 Node bundle 必须使用精确 URL 允许列表，并在最小文件权限、最小环境变量的独立子进程执行。

### 6.1 当前实现

仓库中的 `spider-gateway/` 已实现协议入口、Bearer Token 鉴权、JAR 与 Node bundle 下载校验缓存、Worker 长连接会话、CatVod 目录发现与调用、超时及响应大小限制。服务要求 Node.js 22.13 或更高版本，可以直接在 macOS 启动。

Android DEX 不在 Node/macOS 进程内解释。Gateway 通过 JSON Lines Worker 协议把 JAR 调用传给独立执行器；只有使用 `csp_*` JAR 时才需要实现 `DexClassLoader` 和 Spider ABI 的 Android Worker。CatVod Node bundle 使用 Node Permission Model 运行，不依赖 Android；未配置 Worker 时该路径仍可用。

CatVod 目录接口为 `POST /v1/catvod/catalog`，请求体是 `{ "bundle": "https://.../index.js.md5" }`。Gateway 返回普通 `{ "sites": [...] }` 配置，并为每个站点补充 bundle 地址，客户端随后复用 `/v1/spider/invoke`。

Node 26 环境会额外授予 CatVod 子进程网络权限；无凭据代理配置可以继承。若 `/play` 未返回 URL 但剧集 id 本身是 HTTP/HTTPS 地址，Gateway 按直链返回。Spider 返回的安全 HTTP Header 会继续传给 AVPlayer；VLC 映射 User-Agent、Referer 和 Cookie。

CatVod bundle 下载缓存仍按摘要复用，但可写运行目录按子进程会话独立创建，进程和管道关闭后删除。站点生成的 `db.json` 是临时缓存，不跨会话或应用实例共享，避免中断写入留下的空数据库导致所有首页持续为空；用户接口、收藏、历史和网盘凭据不存放在这个目录。

## 7. 播放规则

type 3 剧集条目中的 URL 实际上可能只是 Spider 的播放 id。客户端选择剧集后必须先调用 `player`：

1. `parse == 0` 且 `url` 非空：直接交给播放器。
2. `parse == 1` 或 `jx == 1`：首版返回明确的暂不支持错误。
3. `url` 是 Gateway 代理 URL：按普通 HTTP 媒体 URL 播放。
4. `header`：首版作为播放上下文保存；第二阶段完成系统播放器和 VLC 的全链路透传。

## 8. 验收标准

- 未配置 Gateway 时，type 3 源显示“需要配置 Spider Gateway”，不影响其他源。
- 配置 Gateway 后，可以选择 type 3 源并完成首页、分类、详情和搜索。
- 选择剧集时调用 `player`，而不是直接播放原始 id。
- 顶层 `spider`、站点级 `jar` 和对象型 `ext` 均能正确传递。
- Gateway 超时、无效 JSON、Spider 异常具有可理解的错误信息。
- type 0/1/4 的现有测试和行为不回归。

## 9. 后续阶段

第二阶段增加 Gateway 媒体代理、播放 Header 全链路、`parse/jx`。第三阶段再评估 `action`、云盘授权、字幕、弹幕、DRM 和 JS/Python Spider。
