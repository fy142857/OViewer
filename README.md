# OViewer

**[中文](README.md)** / [English](README.en.md)

OViewer (Old Viewer) 是使用 Flutter 开发的 Android / iOS E-Hentai、ExHentai 漫画阅读器。项目配置的最低系统版本为 Android 5.0（API 21）和 iOS 12.0。

## 功能

### 浏览与搜索

- 最新、热门、浏览历史、收藏四个首页标签页，支持列表 / 网格切换和加载骨架屏。
- 关键词搜索、分类筛选、最低评分筛选，以及直接输入画廊链接打开详情。
- 搜索联想优先显示匹配的本机搜索历史，再显示标签候选，并去除重复项。
- 标签中文翻译与联想；多词标签按完整匹配短语替换，支持在光标位置插入并保留其他查询条件。
- 标签别名兼容：`artist:"moxueyin | jiuxueran$"` 提交时转换为 `artist:"moxueyin$"`；历史记录保留原输入。
- 相似画廊与标签搜索；每个搜索页面独立保存结果和分页状态，逐级返回时保留原列表及滚动位置。
- 画廊详情、标签分组、评论与投票、评分，以及独立缩略图预览页；支持横竖屏下的拼接缩略图裁剪。

### 阅读器

- 从左到右、从右到左翻页，以及上下连续滚动；支持缩放、进度滑块和底部缩略图条。
- 点击预览图从对应页开始；普通阅读入口恢复上次进度。
- 单击显示 / 隐藏阅读工具栏，并同步显示 / 隐藏系统状态栏。
- 按需获取页码索引和相邻页资源，复用近期详情页、预览页已获取的索引，避免进入时遍历整本画廊。
- 退出阅读器立即取消未完成的大图和缩略图请求；再次进入时按需重新请求。
- 成功加载的图片保留磁盘缓存，有效缓存命中时复用；失败或取消的加载不会作为成功结果缓存，支持再次进入或点击重试。

### 账号与设置

- WebView 登录和手动 Cookie 登录，支持 E-Hentai / ExHentai 切换。
- 本地收藏、云端收藏同步、浏览历史和阅读进度记录。
- 列表加载、刷新及翻页时读取云端收藏标记，列表和网格显示红色爱心；其他设备的收藏变更会在重新获取列表后体现。
- 中文 / English 界面，跟随系统 / 浅色 / 深色主题，默认阅读模式设置。
- “我的标签”“标题语言”“图片尺寸”打开当前站点的设置页面；内嵌页面加载前同步登录 Cookie。
- 手动代理配置、自动代理探测、图片缓存清理和下载存储用量查看。
- 下载任务列表、暂停 / 恢复入口及进度记录；下载功能的限制见下文。

## 当前限制

- 下载模块仍需完善：图片下载目前经文本响应写入文件，下载列表的阅读入口仍打开在线阅读器，尚未形成可靠的离线阅读流程，也不保证应用被系统挂起后继续下载。
- “缓存大小上限”目前保存设置值，尚未接入按磁盘容量淘汰缓存的逻辑；可以手动清理图片缓存。
- iOS 12 是部署目标，不代表已在所有设备上完成兼容性验证。升级 Flutter 或插件时需重新验证旧系统支持。

## 技术栈

| 类别 | 实现 |
|------|------|
| 框架 | Flutter `>=3.13.0 <3.17.0`，Dart `>=3.1.0 <4.0.0`；CI 使用 Flutter 3.16.0 |
| 状态管理 / 依赖注入 | flutter_bloc、equatable、get_it |
| 网络与解析 | dio、http、cookie_jar、html |
| 本地存储 | drift（SQLite）、shared_preferences |
| 图片与阅读 | cached_network_image、flutter_cache_manager、photo_view、scrollable_positioned_list |
| 内嵌网页 | flutter_inappwebview 5.8.x（依赖约束 `^5.8.0`） |
| 自动构建 | GitHub Actions：Android APK、未签名 iOS IPA |

版本约束见 [pubspec.yaml](pubspec.yaml)，解析后的依赖版本见 [pubspec.lock](pubspec.lock)。

## 项目结构

```text
lib/
├── main.dart              # 初始化与依赖注册
├── app.dart               # 应用、主题与全局状态
├── core/
│   ├── constants/         # 站点与接口常量
│   ├── l10n/              # 中文 / English 文案
│   ├── network/           # Cookie、代理、图片请求与阅读会话
│   ├── parser/            # 画廊、搜索、标签等 HTML 解析
│   ├── router/            # 路由与页面生命周期观察
│   ├── storage/           # 数据库、偏好、阅读索引缓存
│   ├── theme/             # 主题
│   └── utils/             # URL、标题、标签查询与联想处理
├── models/                # 数据模型
├── repositories/          # 数据访问
├── blocs/                 # 页面与业务状态
├── widgets/               # 复用组件
└── screens/               # 首页、详情、阅读、搜索、设置等页面

test/                      # 解析器、仓库、BLoC、网络及组件回归测试
.github/workflows/         # Android / iOS 自动构建
```

## 开发环境与快速开始

- 使用符合上述约束的 Flutter / Dart SDK；CI 固定为 Flutter 3.16.0。
- Android 构建使用 JDK 17、Android SDK Platform 35 和 Build Tools 35.0.0；项目配置 AGP 8.6.1、Gradle 8.7，最低运行 API 为 21。
- iOS 本地构建需要 macOS、Xcode 和 CocoaPods；CI 使用 macOS 14 / Xcode 15.4。

```bash
git clone https://github.com/fy142857/OViewer.git
cd OViewer
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run
```

数据库生成文件未纳入版本控制，首次运行或修改数据库模型后需执行代码生成。

```bash
flutter test
flutter analyze
```

测试包含搜索历史与标签联想、嵌套搜索导航、阅读定位、请求取消、图片缓存复用、横竖屏缩略图、Cookie 同步及 HTML 解析等场景。具体用例见 [test/](test/)，自动化测试不能代替真机验证。当前移动端构建 workflow 未配置执行上述测试和静态分析，提交前需单独运行相关检查。

## 构建与安装

### Android APK

```bash
flutter build apk --release
```

产物：`build/app/outputs/flutter-apk/app-release.apk`。

当前 `release` 构建使用 debug 签名配置；正式分发前应配置自己的签名。

### iOS 未签名 IPA

在 macOS 上完成依赖安装与代码生成后，按当前 CI 流程构建：

```bash
flutter build ios --release --no-codesign --config-only
xcodebuild -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -sdk iphoneos \
  -destination generic/platform=iOS \
  -derivedDataPath build/ios/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=NO
mkdir -p build/ios/ipa/Payload
cp -R build/ios/DerivedData/Build/Products/Release-iphoneos/Runner.app build/ios/ipa/Payload/
(cd build/ios/ipa && zip -r OViewer.ipa Payload)
```

产物：`build/ios/ipa/OViewer.ipa`。未签名 IPA 需要经过适用于设备的签名与安装流程，不能直接作为已签名安装包使用。部署目标由 [Podfile](ios/Podfile) 和 iOS 工程配置为 12.0。

### GitHub Actions

| Workflow | 产物 | Runner / 工具链 |
|----------|------|----------------|
| [Build Android APK](.github/workflows/build_android.yml) | `app-release.apk` | ubuntu-latest / JDK 17 / Flutter 3.16.0 |
| [Build iOS IPA](.github/workflows/build_ios.yml) | `OViewer.ipa`（未签名） | macos-14 / Xcode 15.4 / Flutter 3.16.0 |

- 推送到 `main`、`dev`，或创建 `v*` 标签时触发；面向 `main` 的 PR 也会触发。
- 仅修改 Markdown、`docs/` 或 `LICENSE*` 文件的分支推送和 PR 会跳过构建；标签推送和手动触发不受这些路径过滤影响。
- 手动触发：仓库 Actions → 选择 workflow → Run workflow。
- 安装包作为独立 artifact 上传，保留 30 天；`v*` 标签构建还会上传到 GitHub Releases。

发布时使用尚未存在的版本标签，例如：

```bash
git tag v1.0.0
git push origin v1.0.0
```

## 许可证

[Apache License 2.0](LICENSE)
