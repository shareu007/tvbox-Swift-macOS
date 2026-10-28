<div align="center">
  <img src="tvbox/Assets.xcassets/AppIcon.appiconset/mac_128x128_2x.png" width="96" height="96" alt="TVBox 图标">
  <h1>TVBox</h1>
  <p>为 Mac、iPhone 和 iPad 打造的影视客户端。</p>
  <p>
    <a href="#下载">下载</a> ·
    <a href="docs/getting-started.md">使用指南</a> ·
    <a href="https://github.com/shareu007/tvbox-Swift-macOS/releases">更新日志</a> ·
    <a href="https://github.com/shareu007/tvbox-Swift-macOS/issues">问题反馈</a>
  </p>
</div>

TVBox 将影视浏览、视频播放和离线下载放在同一个原生应用中。添加自己的接口后，即可按分类发现影片、搜索资源，或接着上次的进度继续观看。

## 下载

| 平台 | 系统要求 | 下载 |
| --- | --- | --- |
| macOS | macOS 14+，Apple Silicon / Intel | [下载 DMG](https://github.com/shareu007/tvbox-Swift-macOS/releases/latest/download/TVBox-macOS.dmg) · [稳定版说明](https://github.com/shareu007/tvbox-Swift-macOS/releases/latest) |
| iPhone / iPad | iOS / iPadOS 17+ | [下载 IPA](https://github.com/shareu007/tvbox-Swift-macOS/releases/download/ios-v1.2.0-build28/TVBox-iOS-iPadOS-1.2.0-build28-unsigned.ipa) · [预览版说明](https://github.com/shareu007/tvbox-Swift-macOS/releases/tag/ios-v1.2.0-build28) |

Mac 下载后打开 DMG，将应用拖入“应用程序”。iPhone / iPad 的 IPA 未签名，需要自行签名后侧载。完整安装说明见 [使用指南](docs/getting-started.md#安装)。

> TVBox 不内置影视资源或接口。请添加自己有权使用的内容来源。

## 功能

- **发现与搜索**：浏览分类和首页推荐，按年份、地区、类型筛选，搜索不同来源的影视资源。
- **播放与字幕**：切换线路、剧集与来源提供的字幕；Mac 另提供支持 VideoToolbox 硬解的 mpv 播放器和字幕时间偏移。
- **离线观看**：批量选择剧集下载，暂停、继续或重试任务，完成后直接播放本地文件。
- **收藏与续播**：保存想看的影片，通过播放历史继续观看。
- **接口与直播**：支持 CMS JSON/XML、CatVod 脚本接口及直播列表。Mac 与移动端预览版均内置 CatVod 引擎。
- **原生外观**：浅色、深色与跟随系统主题，适配桌面窗口、手机和平板。

## 快速开始

1. 打开“设置 → 添加点播接口”，输入接口地址并加载。
2. 在首页切换来源、浏览分类，或搜索片名。
3. 进入影片详情，选择线路和剧集开始播放；需要离线观看时点击“下载”。

接口切换、字幕、网盘登录及下载问题，参见 [使用指南与常见问题](docs/getting-started.md)。

## 参与项目

欢迎通过 [Issues](https://github.com/shareu007/tvbox-Swift-macOS/issues) 反馈问题或提出建议。反馈时请说明平台、应用版本、复现步骤，并隐藏截图中的账号凭据和私人接口。

源码构建与本地开发见 [开发文档](docs/development.md)。

## 致谢与许可

基于 [Jstrom2022/tvbox-Swift](https://github.com/Jstrom2022/tvbox-Swift) 继续开发，使用 [MIT License](LICENSE)。感谢 VLC、mpv、Node.js 等开源组件，相关许可见 [第三方声明](THIRD_PARTY_NOTICES.md)。
