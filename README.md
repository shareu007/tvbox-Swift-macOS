# TVBox-Swift

原生 SwiftUI 多媒体客户端，支持 macOS 14+ 与 iOS/iPadOS 17+。本项目基于
[Jstrom2022/tvbox-Swift](https://github.com/Jstrom2022/tvbox-Swift) 继续开发。

## 主要功能

- CMS JSON/XML 数据源（`type=0/1/4`）、分类、搜索、收藏、历史、直播。
- AVPlayer 与 VLCKit 双播放内核，网盘资源支持清晰度选择。
- macOS 内置 CatVod Node Gateway，无需 Android 或单独启动服务。
- 支持 CatVod `index.js` / `index.js.md5`、Basic Auth、校验、会话复用与自动回收。
- 夸克、夸父、盘搜等网盘搜索协议；夸克网页登录获取 Cookie 并原生播放。
- 播放时阻止自动休眠，退出后释放播放器、Timer、Node 与缓存资源。

## 支持边界

| 能力 | macOS | iPhone / iPad |
|---|---:|---:|
| CMS `type=0/1/4` | ✅ | ✅ |
| CatVod Node 动态源 | 内置 | 需外部 HTTPS Gateway |
| Java/DEX `csp_*` JAR | 需兼容 Worker | 需外部 Gateway |
| 夸克账号与原生网盘解析 | ✅ | 暂未内置 |

App 不执行 Java/DEX，也不保证兼容所有第三方规则、网页嗅探、DRM 或解析器。
远程 CatVod 脚本运行在独立子进程中，不会收到用户的网盘 Cookie/Token。

## 构建

需要 Xcode 15+、Swift 5.9+ 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```sh
brew install xcodegen
xcodegen generate
open tvbox.xcodeproj
```

命令行验证：

```sh
xcodebuild test -project tvbox.xcodeproj -scheme tvbox-macOS -destination 'platform=macOS'
cd spider-gateway && npm test
```

## 打包

macOS Universal 2 DMG：

```sh
./package_mac.sh
```

默认产物为 ad-hoc 签名且未公证，公开下载时可能出现 Gatekeeper 提示。

iPhone / iPad Archive 或 IPA：

```sh
cp Config/Templates/Signing.example.xcconfig Config/Local/Signing.xcconfig
cp Config/Templates/ExportOptions.example.plist Config/Local/ExportOptions.plist # 需要 IPA 时
./package_ios.sh --check
./package_ios.sh
```

需要安装与当前 Xcode 匹配的 iOS Platform，并在本机配置 Apple Developer Team。
没有导出配置时只生成 `.xcarchive`；有配置时同时生成 `TVBox.ipa`。

## 配置与隐私

- 私人接口、签名配置和导出选项只放在 Git 忽略的 `Config/Local/`。
- Release 默认打包空预设，不会包含本机数据源。
- 配置 URL、Gateway Token 和网盘凭据保存在当前用户的私有目录，不写入仓库。
- 第三方接口和网盘服务由用户自行选择；请确认来源可信及内容授权。

发布前检查：

```sh
./scripts/audit_public_tree.sh
./scripts/audit_public_tree.sh --history  # 同时检查可达 Git 历史
```

详细配置见 [Config/README.md](Config/README.md)，Gateway 协议见
[spider-gateway/README.md](spider-gateway/README.md)。

## License

项目代码采用 [MIT License](LICENSE)。VLCKitSPM/VLCKit 和内置 Node.js 保留各自
许可证，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。本项目仅供技术学习；
不附带私人影视配置，使用者需自行承担第三方接口、内容版权与账号安全责任。
