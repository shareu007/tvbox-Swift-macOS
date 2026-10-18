# iPhone / iPad 独立运行 CatVod

从 iOS build 28 起，CatVod `.js` 和 `.js.md5` 接口使用 App 内置引擎。
首次添加接口、分类、详情、搜索及播放地址解析均不需要电脑、另装 Node
或填写外部 Spider Gateway。JSON/XML/Remote 接口继续由 Swift 原生加载。
Android Java/DEX `csp_*` JAR 仍需要兼容的外部执行环境。

## 网盘设置

iPhone、iPad 和 Mac 均可通过「设置 → 网盘设置」粘贴、保存或清除
夸克 Cookie 与阿里云盘 refresh token，也可打开官方网页登录页自动提取凭据。
手机上的登录页使用桌面网页模式；若官方页面只提供二维码，需要另一台设备
扫码，或返回手动粘贴。取消或重新载入页面后，旧页面的异步回调不会保存凭据。

两个字段作为一次更新保存，某个字段超出 32 KB 时不会只更新另一项。
清空字段后点击保存会删除该项。凭据不进入点播接口配置或第三方脚本，
仅由本机可信的网盘解析组件使用。iOS 在每次请求前更新引擎配置，
因此保存、更换或清除 Cookie 均不需要重启 App。

当前本机网盘播放链路已接入夸克与 123；123 无需凭据。
阿里 Token 的保存入口与 Mac 对齐，不代表阿里或其他网盘线路已实现本机播放。
缺少或失效的夸克 Cookie 会返回更新凭据的提示。
夸克响应刷新 Cookie 时，可信解析组件可更新当前请求中的凭据，
避免因只读属性导致原画或转码解析失败；刷新结果不自动覆盖用户保存的值。

此前 iOS 的 `prepareGatewayIfNeeded` 没有本地启动分支，脚本目录请求
会直接失败为“请先在设置中配置 Spider Gateway”。仅添加网关设置入口无法
满足独立使用要求。

## 实现

- `MobileSpiderGateway` 按需启动一个原生后台线程上的 Node 引擎，通过只监听
  `127.0.0.1`、随机端口且带会话鉴权的内部接口复用现有 Spider 协议。
- `Vendor/MobileNodeRuntime` 通过 Swift Package Manager 固定下载
  [nodejs-mobile 24.21.0-0](https://github.com/fogtape/nodejs-mobile/releases/tag/v24.21.0-0)
  的完整 iOS XCFramework，校验 SHA-256
  `11ce3f366dc5f5f2f58a35186b257edc4fa365f2aeb1c0fe963c35728495b492`。
  该移动端维护版本由 fogtape 提供，发布标签标记为 prerelease，基于上游
  Node 24.21.0；许可证随源代码及 App 打包。设备与模拟器切片均为 arm64，
  iOS 模拟器开发需要 Apple Silicon Mac。
- 引擎使用无 JIT 的 iOS 构建。CatVod 在可终止的 V8 工作线程中运行，复用
  现有生命周期适配、站点初始化顺序、缓存、超时和响应大小限制。
- 运行包从 App 内资源加载，不在手机上启动子进程。工作线程内的相对数据库
  路径映射到会话目录。Node 初始工作目录设为专用缓存，避免其隐式的当前
  目录读权限覆盖 iOS 默认的根目录。
- 主引擎与脚本线程分别设置文件权限。脚本线程不允许原生扩展、子进程、
  再创建工作线程或访问携带凭据的原生桥接。公开文件描述符 API 和
  `process.binding` 另行限制，防止读写宿主已经打开的文件。
- 工作线程共享宿主 OS 进程，不提供操作系统进程隔离。下载白名单、MD5
  校验、重定向、私网限制与既有网关规则一致。
- 会话 Token 和网盘凭据通过引擎主线程可访问的 Node-API 桥接读取，
  不写入命令参数、环境变量或启动文件，不传入第三方脚本工作线程。
- 切换接口会更新白名单；清空网关设置后再次请求会恢复内部连接，
  不创建第二个 Node 引擎。外部 Gateway 保留为 Android JAR 的可选配置。

## 验证

`MobileSpiderGatewayTests` 在真实 iOS 宿主中验证首次添加接口的
`SettingsViewModel.loadConfig`，仅替换脚本下载边界，实际执行内置 Node、
回环 HTTP、CatVod 工作线程、配置解析及首页到播放地址解析的完整链路。
同一测试验证原生 `fetch` 可用、没有保存外部网关，以及文件和桥接边界。
测试也覆盖未配置 Cookie 时提示登录、保存 Cookie 后播放、更换凭据后继续播放、
清除后再次提示登录，所有网盘 HTTP 请求均使用虚构凭据和固定响应，
不读取真实账号或转存真实网盘文件。

`CloudDriveCredentialFileStoreTests` 与 `CloudDriveLoginCredentialExtractorTests`
在 iOS 和 macOS 上均参与编译，覆盖重新打开后的读取、更新、清除、
批量保存失败的原子性、文件权限和官方登录域名检查。

```sh
xcodegen generate
xcodebuild test -project tvbox.xcodeproj -scheme tvbox \
  -derivedDataPath build/DerivedData \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -only-testing:tvbox-Tests/MobileSpiderGatewayTests
```

发布工作流在 iPhone 和 iPad 上运行此测试，并检查最终设备包确实包含
`NodeMobile.framework` 和 `SpiderGateway/mobile-entry.mjs`。
Node 测试覆盖完整 Spider 动作、初始化切换、异常、退出、死循环恢复及
文件描述符限制。macOS 保持子进程架构。
