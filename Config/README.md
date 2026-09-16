# 本地配置

这个目录把可公开的配置模板与只在本机使用的内容分开。

- `Templates/` 可以提交到 Git，内容只能使用空值或示例值。
- `Local/` 已被 `.gitignore` 整目录忽略，不会上传到 GitHub。
- `Local/TVBoxPresets.json` 保存构建时打入 App 的只读 TVBox 配置预设和接口地址。
- `Local/Signing.xcconfig` 保存 Apple Developer Team ID 和本机专用 Bundle ID。
- `Local/ExportOptions.plist` 保存 iOS 导出方式、Team ID 和证书名称。

首次配置可以执行：

```sh
mkdir -p Config/Local
cp Config/Templates/TVBoxPresets.example.json Config/Local/TVBoxPresets.json
```

签名配置请从公开模板复制后填写：

```sh
cp Config/Templates/Signing.example.xcconfig Config/Local/Signing.xcconfig
```

其中 `TVBOX_IOS_BUNDLE_ID` 必须使用自己唯一的反向域名，避免自动签名时与其他开发者的 App ID 冲突。打包脚本使用 Xcode 自动签名，不会导入 P12、复制 provisioning profile 或解锁登录钥匙串。

iOS 导出配置请从公开模板复制后再填写：

```sh
cp Config/Templates/ExportOptions.example.plist Config/Local/ExportOptions.plist
```

可以先运行 `./package_ios.sh --check`，只检查 iOS 平台、Team、Bundle ID、证书和导出配置，不会清理或生成安装包。

Debug 构建会优先将 `Config/Local/TVBoxPresets.json` 作为候选配置打入 App；本机文件不存在时使用公开模板，因此公开仓库可以直接构建。用户手动输入或从候选中成功加载的接口，会加入 App 内的“我的点播配置”，并保存在用户私有的 Application Support 配置文件中；运行时不会写回 `Config/Local/` 或仓库。

Release 构建默认只打入公开模板，避免上传 App/DMG 时泄露本机接口。确实要构建个人使用的 Release 时，可以显式开启：

```sh
TVBOX_INCLUDE_LOCAL_CONFIG=1 ./package_mac.sh
```

不要把启用了本机配置的 App、DMG 或构建产物发布到公开 Releases；接口会作为资源存在于安装包中。

提交前可用以下命令确认本机目录没有被跟踪：

```sh
./scripts/audit_public_tree.sh
```

脚本会检查本机配置、签名材料、构建产物、凭据 URL、私钥头和本机绝对路径是否误入 Git。
