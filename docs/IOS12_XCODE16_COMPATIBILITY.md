# iOS 12 / Xcode 16 兼容修补与验收

## 约束及适用范围

本轮保留本地 Flutter 3.13.9、CI Flutter 3.16.0、`macos-15`、Xcode 16.0，以及应用的 iOS 12.0 部署目标。采用仓库内 WebView 5.8 修补版，不升级 Flutter、数据库、Android 构建工具或 WebView 主版本。

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

## 本轮状态

| 项目 | 状态与证据 |
| --- | --- |
| 官方归档与补丁范围 | 本地通过：归档 SHA-256、270 个文件的完整清单与允许转换 |
| Flutter 3.13 回归 | 84 项通过，覆盖登录、Cookie、注销、网页设置、阅读及图片保存 |
| Flutter 3.13 Android 调试构建 | 通过 |
| Python 脚本测试 | 66 项通过，包含新增负向校验 |
| Flutter 3.16 静态检查 | 通过：157 条既有诊断，无新增错误或警告 |
| Flutter 3.16 全量回归 | 1,142 项通过；pub.dev 解析，代码生成成功 |
| Android / iOS 候选构建 | 待完成 |
| 安装包版本、哈希与 iOS 最低版本声明 | 待完成 |
| iOS 12 真机 | 未验收，发布前必须完成 |

后续根据实际候选构建与产物检查结果更新本表。构建通过、最低版本声明通过、真机通过须分别记录。

## iOS 12 发布前真机清单

- 冷启动及后台返回，无启动崩溃或动态库加载错误。
- 登录、Cookie 同步、网页设置、注销及重新登录；检查 JavaScript 调用结果。
- 单页 / 双页与三种阅读方向，翻页和预加载数量调整。
- 下载、离线阅读及杀进程后重进。
- 覆盖安装前后的数据库、收藏、历史、设置和离线文件保留。
- 图片保存权限首次请求、拒绝及允许后保存；通知权限与通知展示。

本轮只构建和验收候选，不执行正式发布。
