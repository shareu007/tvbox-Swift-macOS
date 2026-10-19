# 开发与构建

## 安装包与源码对应关系

GitHub Release 可以包含不同平台的后续构建，下载前请查看文件名及版本说明。

- macOS 1.2.0（build 26）：源码标签 [`v1.2.0`](https://github.com/shareu007/tvbox-Swift-macOS/tree/v1.2.0)。
- iPhone / iPad 1.2.0（build 28）：源码标签 [`ios-v1.2.0-build28`](https://github.com/shareu007/tvbox-Swift-macOS/tree/ios-v1.2.0-build28)，包含移动端独立 CatVod 引擎。

Release 页面自动生成的 Source code 压缩包对应该页面的标签；1.2.0 页面后补的 iOS build 28 请使用上面的专用源码标签。

## 环境与工程

安装支持目标平台的 Xcode、对应平台组件及 XcodeGen。工程配置以 `project.yml` 为准，修改后重新生成工程：

```sh
brew install xcodegen
xcodegen generate
open tvbox.xcodeproj
```

所有编译、测试、归档、日志和打包产物统一放在仓库根目录的 `build/DerivedData`，不创建其他构建目录。

```sh
xcodebuild -project tvbox.xcodeproj -scheme tvbox-macOS \
  -configuration Debug -derivedDataPath build/DerivedData build
xcodebuild -project tvbox.xcodeproj -scheme tvbox \
  -configuration Debug -derivedDataPath build/DerivedData build
```

## 测试

```sh
xcodebuild test -project tvbox.xcodeproj -scheme tvbox-macOS \
  -derivedDataPath build/DerivedData -destination 'platform=macOS'
```

iOS 测试需选择本机已经安装且匹配当前 Xcode 的模拟器。Gateway 测试在 `spider-gateway/` 目录执行：

```sh
npm test
```

## macOS 打包

```sh
./package_mac.sh
```

脚本生成 Universal 2 DMG，支持 Apple Silicon 和 Intel。默认使用 ad-hoc 签名且未公证。产物位于 `build/DerivedData/Packages/TVBox-macOS.dmg`。

## iOS / iPadOS 打包

需要本机配置 Apple Developer Team 和唯一 Bundle ID：

```sh
mkdir -p Config/Local
cp Config/Templates/Signing.example.xcconfig Config/Local/Signing.xcconfig
cp Config/Templates/ExportOptions.example.plist Config/Local/ExportOptions.plist
```

填写本机配置后检查环境并打包：

```sh
./package_ios.sh --check
./package_ios.sh
```

没有导出配置时只生成 `.xcarchive`；有配置时同时导出 `TVBox.ipa`。归档位于 `build/DerivedData/Archives/`，导出包位于 `build/DerivedData/Packages/`。特定发布标签的 CI 未签名包以该标签下的工作流说明为准。

## 配置与发布检查

- 私人接口、签名和导出配置只放在 Git 忽略的 `Config/Local/`。
- Release 默认使用空接口预设，不应包含本机接口、账号凭据、运行数据库或用户文件。
- 公开发布前运行源码隐私检查：

```sh
./scripts/audit_public_tree.sh
./scripts/audit_public_tree.sh --history
```

详细说明见 [本地配置](../Config/README.md) 与 [Spider Gateway](../spider-gateway/README.md)。
