# iPhone / iPad 通用适配

适配日期：2026-10-18。最低系统版本保持 iOS / iPadOS 17。

## 行为

- iPhone 使用标签导航；iPadOS 18 及以上使用系统可切换侧栏的标签导航，17 保留标签导航。
- 首页来源入口移到导航栏，分类栏独占一行。首页、搜索、收藏和历史根据当前 size class 调整海报尺寸；iPad 分屏会恢复紧凑尺寸。
- 播放中的详情页在内容宽度达到 900 点时并排展示播放器和选集，窄窗口上下排列。通过 `AnyLayout` 保留播放器视图身份。
- 系统和 VLC 播放器共用移动端控制行，触控区域至少 44 点。窄屏通过“播放操作”菜单提供前进、后退和下一集；宽屏直接显示这些按钮。
- 全屏控件遵守安全区域，详情页暂时消失时保留全屏正在使用的播放会话。
- 直播无源页可返回首页；频道选择面板最大宽度 640 点，有明确的关闭按钮。下拉关闭手势只放在面板标题处，避免抢占列表滚动。
- 移动端播放期间保持屏幕唤醒，暂停或退出所有播放页面后恢复自动锁屏。设置和个人中心限制正文宽度。
- iOS 目标明确支持设备族 `1,2`，允许 iPad 多任务。关闭依赖包不支持的 Mac Catalyst 目标，桌面端继续使用独立 macOS 目标。

## 验证结果

- `tvbox-macOS` Debug 构建通过。
- 13 项相关 XCTest 通过：`AdaptiveMediaLayoutTests`、`PlaybackSleepPreventerTests`、`HomeCinemaLayoutTests`、`DetailCinemaLayoutTests`。覆盖宽窄窗口几何布局、缩放时播放器身份保持、播放 owner 引用计数和首页/详情视觉回归。
- 使用已安装的 iOS Simulator SDK 和真实 VLC 模块，对全部 iOS 源码完成类型检查及独立 QA 程序编译、链接。
- 在 iOS 18.6 的 iPhone 16 Pro 和 iPad Pro 11-inch (M4) 模拟器上检查布局样例。确认 iPhone 首页、播放控件、直播空页返回入口，以及 iPad 横屏播放器/选集双栏。
- QA 程序使用真实 `DetailView`、内存 SwiftData 和本地生成的视频验证系统播放器：进入全屏时保留约 21 秒的播放进度，恢复播放并退出全屏后在约 32 秒继续内联播放。

测试结果位于 `build/DerivedData/AdaptiveLayoutTests.xcresult`，截图位于 `build/DerivedData/layout-screenshots/`。QA 程序及视频均为忽略目录内的验证产物，不包含真实用户接口、影片或凭据。本机已安装的 TVBox 未被替换。

## 尚未完成的环境验证

原生 `xcodebuild` 的 iOS 构建和 iPhone XCTest 命令已尝试，但 Xcode 26.6 将目标标记为不可用，提示 `iOS 26.5 is not installed`。本机已有 iOS 18.6 运行时且可启动，因此使用独立 QA 程序完成上述模拟器检查；这不等同于原生 iOS scheme 构建、签名归档或 XCTest 通过。

补齐 Xcode 的 iOS 平台组件后，仍需运行原生 iOS scheme 测试并在真机上验证网络媒体、VLC 解码和分屏多任务。

```sh
xcodegen generate
xcodebuild test -project tvbox.xcodeproj -scheme tvbox \
  -derivedDataPath build/DerivedData \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
xcodebuild test -project tvbox.xcodeproj -scheme tvbox \
  -derivedDataPath build/DerivedData \
  -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)'
```
