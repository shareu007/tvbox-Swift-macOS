# 功能回归记录（2026-09-24）

## 结果

基于 1.0.7，macOS 全量 XCTest 最终 **187 项通过、0 失败**；接口网关 **54 项通过、0 失败、0 跳过**。公开树隐私检查和 `git diff --check` 通过。

本轮发现并修复了资源抽检结果过期后，列表计数与行标签不同步的问题。修复已经过自动化验证，尚未替换本机已安装应用，也未发布到 GitHub。

## 覆盖情况

| 功能 | 本轮证据 | 结果与边界 |
| --- | --- | --- |
| 已保存接口启动、恢复失败、重试与取消 | AppStartupRoutingTests | 通过；本轮没有重新做冷启动人工验证 |
| 首页协议解析、分类、电影混合推荐、空首页回退 | HomeSourceProtocolTests、SourceCategoryParsingTests、HomeSourceRecoveryTests、HomeCategoryGroupTests | 通过；实际首页显示 103 部影片和电影推荐 |
| 年份、国家/地区筛选 | HomeBrowseFilterTests + 已安装应用操作 | 通过；1987 年与日本组合筛选得到对应影片，重置正常 |
| 首页超时、停止、缓存与晚到结果隔离 | HomeLoadBudgetTests | 通过 |
| 搜索、同剧资源汇总、详情 | 自动化 + 已安装应用操作 | 实际搜索返回多来源资源，资源列表及详情可打开 |
| 在线播放与播放实测记录 | 已安装应用操作 | 成功出画面并显示中英字幕，配置页正确记录 1 个站点成功样本；不代表完整片库可播放 |
| 系统/VLC 字幕 | SubtitleSelectionTests + SubtitleControlsSnapshotTests | 合成双字幕视频测试覆盖发现、自动选择中文、手动切换、关闭、换集及重绑；已核对两个播放器均显示字幕按钮 |
| 重复导入提示、保存配置切换 | ConfigInspectionDismissalTests、SavedConfigSwitchTests | 自动化通过；本轮人工切换、重复导入未完成 |
| 协议支持与首页/播放实测分离 | SourceVerificationTests + 实际播放后配置页 | 自动化通过，实际播放记录可见 |
| 网盘凭据、分享提取、资源检查、图片与运行时安全 | 对应 XCTest 和 Node 测试 | 自动化通过；未进行真实网盘登录/授权流程 |
| 分类窄屏布局、字幕控制栏 | 渲染测试及图片核对 | 已检查；快照不是交互或真实设备测试 |
| 收藏、历史、直播 | 未完成本轮交互回归 | 不计为通过 |

## 修复：抽检状态刷新不同步

实际操作中，播放后返回资源列表，顶部显示“0 个抽检可用”，行仍显示“抽检可用”。抽检结果有效期为 60 秒，但行视图没有接收 TimelineView 的更新时间；其输入不变时，标签可能保留旧渲染。

现在将同一个刷新时间显式传递给搜索结果、资源计数、筛选、排序、行标签、图标及颜色。继续使用既有的 5 秒刷新间隔，因此过期显示最多存在一个刷新间隔的延迟。没有改变抽检有效期或网络请求策略。

新增 `testExpiredVerificationLabelAgreesWithAvailableCount`，以可控时间验证过期计数、标签和筛选一致。修改前测试返回旧“抽检可用”标签而失败，修改后通过。它验证时间判断一致性；实际 SwiftUI 行刷新仍需在可用桌面重新走一次原操作流程。

## 未完成项

- iOS 模拟器测试：当前 Xcode 报所需 iOS 26.5 平台未安装，已有 iOS 18.6 模拟器不能作为当前 scheme 的测试目标。没有下载或修改开发环境，不能声称 iOS 已验证。
- 手动回归途中，桌面工具对 TVBox 和访达均返回 `cgWindowNotFound`；重试及窗口查询未恢复。已请求解锁并打开应用，尚未获得可继续操作的窗口。
- 待补测：修复后资源状态过期的界面表现、配置切换和重复导入、收藏增删与历史续播、直播切换、冷启动。所有第三方源的长期可用性也不在本次样本验证保证范围内。

## 复现命令

```sh
xcodebuild test -project tvbox.xcodeproj -scheme tvbox-macOS \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=

(cd spider-gateway && node --test)
./scripts/audit_public_tree.sh
```

界面刷新实现参考 Apple [TimelineView](https://developer.apple.com/documentation/swiftui/timelineview) 的 `context.date` 传参方式。
