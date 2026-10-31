# iOS 12 / Xcode 16 兼容修补与验收

## 约束及适用范围

候选 135 的修补验收使用本地 Flutter 3.13.9、CI Flutter 3.16.0、`macos-15`、Xcode 16.0，以及应用的 iOS 12.0 部署目标。采用仓库内 WebView 5.8 修补版，不升级 Flutter、数据库、Android 构建工具或 WebView 主版本。后续 Xcode 16.4 对照结果单独记录如下。

Apple 官方不支持使用 Xcode 16 面向 iOS 12 部署。以下“最低版本通过”仅证明配置与 Mach-O 声明，不代表 Apple 官方支持，也不能代替 iOS 12 真机运行验收。参见 [Apple DTS 说明](https://developer.apple.com/forums/thread/783390)。

## 变更

- `third_party/flutter_inappwebview` 保存 5.8.0 的 270 个运行及许可文件；通过根路径依赖供本地和 CI 共用。来源、许可及完整校验清单见该目录的 `OVIEWER_PATCH.md` 和 `UPSTREAM.json`。
- 只修改插件包版本后缀及 iOS `evaluateJavaScript` 重写签名；Swift 6 编译器分支带 `@MainActor @Sendable`，旧分支保持原实现。Apple Pay 判断、空回调和转发逻辑保持一致。
- Podfile 先检查 Pod 声明及工程有效部署版本，再将低于 12 的目标提高到 12。高于 12 或无法解析的非空版本停止构建，不能向下覆盖。
- iOS 打包前检查主应用、嵌入框架与动态库的所有设备架构切片。主应用声明必须为 12.0，所有切片不得要求高于 12.0；缺失或无法识别的二进制不得通过。
- 报告单独上传为 `ios-compatibility` artifact；现有 `build-metadata` 格式及候选版本流程保持原样。

## 检查命令

```text
python -m scripts.verify_webview_vendor --download-upstream --check-resolution
python -m unittest discover -s scripts/tests -v
ruby scripts/tests/ios_deployment_target_guard_test.rb
python -m scripts.versioning.analyze
flutter test --no-pub --reporter expanded
python -m scripts.verify_ios_minimum --app build/ios/DerivedData/Build/Products/Release-iphoneos/Runner.app --report build/ios/ios-compatibility.json
```

Ruby 检查需要 CocoaPods / Xcodeproj，在 macOS CI 上运行。Windows 本地不以 mock 测试冒充原生 Swift 编译验证。旧 Xcode 条件分支没有本轮原生编译环境。

## Xcode 16.0 验收（候选 135）

| 项目 | 状态与证据 |
| --- | --- |
| 官方归档与补丁范围 | 本地及双端 CI 通过：归档 SHA-256、270 个文件的完整清单与允许转换 |
| Flutter 3.13 回归 | 84 项通过，覆盖登录、Cookie、注销、网页设置、阅读及图片保存 |
| Flutter 3.13 Android 调试构建 | 通过 |
| Python 脚本测试 | 66 项通过，包含新增负向校验 |
| macOS Pod 检查测试 | 4 项 / 9 个断言通过：版本比较、父 Pod 继承、工程继承及条件 xcconfig |
| Flutter 3.16 静态检查 | 通过：157 条既有诊断，无新增错误或警告 |
| Flutter 3.16 全量回归 | 本地、Android CI、iOS CI 各 1,142 项通过；pub.dev 解析，代码生成成功 |
| Android 候选 1.11.1+135 | [构建通过](https://github.com/fy142857/OViewer/actions/runs/41239612514)，下载 APK 的版本、哈希、固定正式签名及候选提交均已核验 |
| iOS 候选 1.11.1+135 | [构建通过](https://github.com/fy142857/OViewer/actions/runs/41239619832)，Xcode 16.0 原生编译成功，未签名 IPA 的版本、哈希及候选提交均已核验 |
| iOS 最低版本声明 | 通过：下载 IPA 重新检查结果与 CI 报告一致；28 个二进制、11 个应用／框架目录；主应用 12.0，所有设备架构切片均不高于 12.0 |
| iOS 12 真机 | 未验收，发布前必须完成 |

验收日期：2026-11-01。机器可读记录：[双端产物验收](benchmarks/ios-compatibility/1.11.1+135/acceptance.json)、[最低版本声明报告](benchmarks/ios-compatibility/1.11.1+135/minimum-os.json)。报告中的 `runtime_device_test: not_performed` 表示未进行真机验收。构建通过、最低版本声明通过、真机通过分别记录。

首次候选 134 的 iOS 构建被新增 Ruby 测试拦截：CocoaPods Consumer 没有 `deployment_target` 方法。已改用 `Specification.deployment_target(:ios)`，并验证子 Pod 继承要求；候选 135 的该项检查已通过。

候选 135 构建提交：`1d7ac858c2561d8f2924ae6d1e70d5bb2a0178d9`。APK SHA-256：`b2acccba24f91aab71bfbce7177d84e378dc0012afd7f1dc1bd8102406067e40`；正式签名证书 SHA-256：`a30360a24fda76486fc152cb9e2e8cc5e7578c42c46d6aa430f3ae35adfa34e4`。

IPA SHA-256：`51e5909c2ad8f675b3859a2b78663b4b1b0bdfd1eaf9d1deb5257bb5708c7cf5`。实际 Mach-O 最低版本包含 7.0、11.0、12.0，均未超过应用要求的 12.0；检查同时覆盖嵌入的 Swift 动态库。

## Xcode 16.4 对照构建（候选 136）

2026-11-01 按维护者要求将工作流固定到 Xcode 16.4，保留 Flutter 3.16.0、全部测试、仓库内 WebView 5.8 修补版及 iOS 12.0 部署要求。使用镜像预装的 iOS 18.5 平台，保留初始化与组件清单输出，移除 `xcodebuild -downloadPlatform iOS`。

候选构建提交：`318b0ee9da7fb517d03cf87d86f3503a57519975`。候选准备首次在分发阶段未读到就绪记录；核对实时台账与源码一致后，重试同一准备运行成功，沿用 136，没有重新分配版本号。

| 项目 | 状态 |
| --- | --- |
| Xcode 16.4 选择、预装平台初始化 | 通过；初始化 49 秒，对比候选 135 的平台安装 227 秒减少 178 秒 |
| 脚本测试、静态检查 | 双端各 66 项脚本测试通过；各 157 条既有诊断，无新增错误或警告；macOS Pod 检查 4 项 / 9 个断言通过 |
| Flutter 全量测试 | Android / iOS CI 各 1,142 项通过，包含预加载组合场景 |
| 原生构建 | Android APK 和 Xcode 16.4 未签名 IPA 均构建成功 |
| 安装包验收 | 下载产物的候选提交、版本和 SHA-256 全部匹配；APK 正式签名匹配 |
| iOS 最低版本声明 | 下载 IPA 的 28 个二进制、11 个应用／框架目录与 CI 报告一致；主应用 12.0，所有设备切片均不高于 12.0 |
| iOS 12 真机 | 未验收，不能沿用二进制声明检查代替 |

构建：[iOS 136](https://github.com/fy142857/OViewer/actions/runs/41243120077)、[Android 136](https://github.com/fy142857/OViewer/actions/runs/41243113182)。

归档：[双端产物验收](benchmarks/ios-compatibility/1.11.1+136/acceptance.json)、[最低版本声明报告](benchmarks/ios-compatibility/1.11.1+136/minimum-os.json)、[步骤耗时对比](benchmarks/ios-compatibility/1.11.1+136/timings.json)。

APK SHA-256：`05b0fac7e699ed5ad52f75d50e6ae04dadd90029b364d982ba1acee701ea7244`。IPA SHA-256：`a1c8dc970fcc8f901620ac7eabd5991c2f28d85caf9579b20cc1b6e32cfc9907`。Android 正式签名证书与候选 135 相同。

| iOS 构建阶段 | Xcode 16.0 / 135 | Xcode 16.4 / 136 |
| --- | --- | --- |
| 作业总耗时 | 20 分 51 秒 | 15 分 49 秒 |
| 平台准备 | 3 分 47 秒（含下载） | 49 秒（预装平台） |
| Flutter doctor | 60 秒 | 19 秒 |
| 获取依赖 | 25 秒 | 4 秒 |
| 代码生成 | 78 秒 | 54 秒 |
| Flutter 测试 | 9 分 42 秒 | 9 分 38 秒 |
| iOS 原生构建 | 3 分 11 秒 | 2 分 28 秒 |

本次作业比候选 135 减少 5 分 02 秒，约 24%。该对比不含候选准备重试、排队和本地下载验收；两次运行的环境负载与缓存可能不同，不能将全部差异归因于编译器版本。平台准备减少 178 秒，完整测试的耗时基本相同。本轮没有调整 doctor 或测试执行策略，也未配置运行时缓存。

## 移除初始化并缩减试构建测试（候选 137）

2026-11-01 按维护者要求，移除整个 `Initialize preinstalled iOS platform` 步骤，包括 `runFirstLaunch`、`simctl list runtimes` 和 `showsdks`；继续使用 Xcode 16.4，保持 iOS 12.0 配置与二进制检查。

本次通过 `skip_reader_prefetch_tests=true` 排除 `reader_prefetch_slow` 标签的 64 个 `reader_prefetch_issue71_test.dart` 组合场景。快速预读策略、设置、其他阅读器与平台测试仍执行。开关默认关闭，后续自动候选构建、PR 检查及不勾选该开关的手动构建仍运行全量测试。

候选源码：`325aed4555a872a575caf2d209a3de93d4261d9d`；构建提交：`7b17b6ac9060085458f9437845fc96cf0330c3e1`。自动启动的全量运行 41245371921（iOS）和 41245364505（Android）已取消，改用同一候选、显式启用上述开关的试构建，没有为重试另行分配版本号。

本地 Flutter 3.16 筛选后的 1,078 项测试通过；不传排除参数时，抽查的一个标记场景仍正常执行。静态检查无新增错误或警告，66 项脚本测试通过。本地 SDK 解析已恢复 Flutter 3.13。

试构建：[iOS 137](https://github.com/fy142857/OViewer/actions/runs/41245466504)、[Android 137](https://github.com/fy142857/OViewer/actions/runs/41245462893) 均成功。两端日志均确认 `SKIP_READER_PREFETCH_TESTS: true`、排除 64 个慢场景，以及 1,078 项测试通过；各 66 项脚本测试通过，157 条既有静态诊断没有新增错误或警告，macOS Pod 检查 4 项 / 9 个断言通过。

下载的 APK / IPA 版本、候选提交与哈希均已核验，APK 正式签名匹配。IPA 的 28 个二进制、11 个应用／框架目录与 CI 最低版本报告一致，主应用声明为 12.0，全部设备切片均未高于 12.0。构建成功证明本次使用预装 Xcode 16.4 时不需要专门的初始化步骤；并不表示后续工具内部完全没有启动服务或执行初始化。

归档：[产物验收及测试范围](benchmarks/ios-compatibility/1.11.1+137/acceptance.json)、[最低版本报告](benchmarks/ios-compatibility/1.11.1+137/minimum-os.json)、[步骤耗时](benchmarks/ios-compatibility/1.11.1+137/timings.json)。APK SHA-256：`d10ad4722ef04ca8be1763d9030ba98833456156bb0c70c07f24529fc5089d2f`；IPA SHA-256：`e097982e1d7beddbcd076f23b1fb5e1e17b13b60205a4ee286ea72b99af8145b`。

| iOS 构建阶段 | 候选 136（全量） | 候选 137（缩减测试） |
| --- | --- | --- |
| 作业总耗时 | 15 分 49 秒 | 11 分 07 秒 |
| 专门的平台初始化步骤 | 49 秒 | 已移除 |
| Flutter doctor | 19 秒 | 66 秒 |
| Flutter 测试 | 9 分 38 秒 / 1,142 项 | 4 分 05 秒 / 1,078 项 |
| iOS 原生构建 | 2 分 28 秒 | 3 分 31 秒 |

本次总耗时减少 4 分 42 秒，测试阶段减少 5 分 33 秒。doctor 的 47 秒增量几乎抵消被移除步骤的 49 秒，原生构建也增加了 63 秒；运行器负载、缓存及服务启动的影响未单独隔离，不能把全部时差归因于初始化步骤的删除。这些时间不含候选准备、被取消的自动运行和本地验收。

本轮属于缩减测试范围的试构建，不能记作 1,142 项全量测试通过；iOS 12 真机验收状态仍为未完成。后续新候选默认执行全量测试，试构建跳过须显式开启开关。

## iOS 12 发布前真机清单

- 冷启动及后台返回，无启动崩溃或动态库加载错误。
- 登录、Cookie 同步、网页设置、注销及重新登录；检查 JavaScript 调用结果。
- 单页 / 双页与三种阅读方向，翻页和预加载数量调整。
- 下载、离线阅读及杀进程后重进。
- 覆盖安装前后的数据库、收藏、历史、设置和离线文件保留。
- 图片保存权限首次请求、拒绝及允许后保存；通知权限与通知展示。

本轮只构建和验收候选，不执行正式发布。
