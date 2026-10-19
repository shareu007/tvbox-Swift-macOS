# TVBox-Swift

适用于 Mac、iPhone 和 iPad 的原生多媒体客户端。添加自己的影视接口，即可浏览分类、搜索影片、播放视频或下载后离线观看。

## 下载与安装

| 平台 | 系统要求 | 当前安装包 |
| --- | --- | --- |
| Mac（Apple Silicon / Intel） | macOS 14 及以上 | [下载 DMG · 1.2.0（build 26）](https://github.com/shareu007/tvbox-Swift-macOS/releases/download/v1.2.0/TVBox-macOS.dmg) |
| iPhone / iPad | iOS / iPadOS 17 及以上 | [下载 IPA · 1.2.0（build 28，未签名预览版）](https://github.com/shareu007/tvbox-Swift-macOS/releases/download/v1.2.0/TVBox-iOS-iPadOS-1.2.0-build28-unsigned.ipa) |

[查看版本说明与文件校验值](https://github.com/shareu007/tvbox-Swift-macOS/releases/tag/v1.2.0) · [全部版本](https://github.com/shareu007/tvbox-Swift-macOS/releases)

- **Mac**：打开 DMG，将 TVBox 拖入“应用程序”。安装包尚未经过 Apple 公证，首次打开可能出现系统提示。
- **iPhone / iPad**：IPA 是通用设备包，未使用 Apple 证书签名，需自行签名后侧载，不能直接点击安装。
- **首次使用**：安装包不附带影视接口，需要自行添加。

## 主要功能

- **浏览与搜索**：首页推荐、分类、年份 / 地区 / 类型筛选，支持收藏、播放历史和直播。
- **多种播放内核**：系统播放器、VLC，以及 Mac 内置的 mpv；mpv 支持 VideoToolbox 硬件解码。
- **字幕与清晰度**：选择视频内封字幕或来源提供的外挂字幕，支持关闭字幕；Mac 的 mpv 还可调整字幕时间偏移，网盘资源可按来源切换清晰度。
- **离线下载**：选择一集或多集加入队列，查看进度、暂停续传，下载完成后本地播放。
- **接口兼容**：支持 CMS JSON/XML 和 CatVod `.js` / `.js.md5` 接口；Mac 与 iPhone / iPad build 28 均内置 CatVod 引擎，无需另启电脑服务。
- **外观与设备适配**：浅色、深色或跟随系统，适配桌面窗口、手机及平板布局。

## 开始使用

1. 在“设置 → 添加点播接口”输入接口地址，加载成功后可在“我的点播配置”中切换。
2. 在首页选择来源与分类，或通过搜索查找影片，进入详情选择线路和剧集播放。
3. 需要离线观看时，在影片详情点击“下载”，再到下载管理中查看任务。
4. Mac 上需要登录的网盘资源，可在“设置 → 网盘设置”中配置账号凭据。

## 使用说明

- 影片、海报、分类、筛选条件、字幕和播放地址由第三方接口提供，可用性取决于来源；画面中已经压制的字幕无法单独切换。
- 离线下载支持可直接读取的视频文件和普通点播 HLS；直播、DRM 保护内容及部分特殊流暂不支持。退出应用后不会继续下载。
- iPhone / iPad build 28 已支持独立运行 CatVod，尚未提供 Mac 版的网盘凭据设置入口。
- Android Java/DEX `csp_*` JAR 不在 App 内直接执行，需要兼容的外部运行环境。并非所有第三方规则、网页嗅探或解析器均受支持。
- 请使用可信且有权访问的接口与内容，不要在公开反馈中上传 Cookie、Token 或私人接口地址。

## 开发资料

源码构建、测试、打包及本地配置说明见 [开发文档](docs/development.md)。

## 项目来源与许可

本项目基于 [Jstrom2022/tvbox-Swift](https://github.com/Jstrom2022/tvbox-Swift) 继续开发，项目代码采用 [MIT License](LICENSE)。VLC、mpv、Node.js 等组件的许可证见 [第三方声明](THIRD_PARTY_NOTICES.md)。
