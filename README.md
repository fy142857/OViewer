# OViewer

OViewer (Old Viewer): Flutter Android/iOS 跨平台 E-Hentai/ExHentai 漫画阅读器，兼容 iOS 12+。

## 技术栈

| 类别 | 选型 |
|------|------|
| 框架 | Flutter 3.13.9–3.16.x / Dart 3.1+ |
| 状态管理 | flutter_bloc 8.x + equatable |
| 依赖注入 | get_it |
| 网络 | dio 5.x + cookie_jar |
| 数据解析 | html (HTML → Model) |
| 本地存储 | drift (SQLite) + shared_preferences |
| 图片 | cached_network_image + photo_view |
| CI/CD | GitHub Actions (APK + unsigned IPA) |

## 项目结构

```
lib/
├── main.dart                    # 入口 + DI 注册
├── app.dart                     # MaterialApp + BlocProvider
├── core/
│   ├── constants/               # AppConstants, ApiEndpoints
│   ├── network/                 # DioClient, CookieManager, ApiException
│   ├── parser/                  # HTML 解析器 (列表/详情/图片/搜索)
│   ├── storage/                 # drift 数据库, SharedPreferences
│   ├── router/                  # 路由表
│   └── theme/                   # 亮色/暗色主题
├── models/                      # 数据模型 (9 个)
├── repositories/                # 数据仓库层 (8 个)
├── blocs/                       # BLoC 状态管理 (9 组 event/state/bloc)
├── widgets/                     # 可复用组件 (8 个)
└── screens/                     # 页面 (9 个)
```

## 功能列表

### P0 — 核心功能
- [x] 画廊列表浏览（Latest / Popular / Watched / Favorites Tab）
- [x] 列表视图 + 瀑布流视图切换，Shimmer 骨架屏加载
- [x] 关键词搜索 + 分类筛选 + 最低评分筛选 + 搜索历史
- [x] 画廊详情（封面 Hero 动画、元数据、标签分组、评论、缩略图预览）
- [x] 漫画阅读器（左右翻页 / 右左翻页 / 垂直连续滚动，PhotoView 缩放，预加载）
- [x] Cookie 登录（WebView 自动提取 + 手动输入）
- [x] 收藏管理（本地 SQLite + 云端同步）
- [x] 浏览历史（自动记录 + 阅读进度条）

### P1 — 增强功能
- [x] 标签翻译（EhTagTranslation 中文翻译，自动缓存）
- [x] 下载管理（后台队列，暂停/恢复，进度追踪）
- [x] 设置中心（主题、缓存管理、代理配置、阅读偏好）
- [x] 阅读器缩略图条快速跳页

### P2 — 完善功能
- [x] 画廊评分对话框
- [x] 评论投票（赞/踩）
- [x] E-Hentai / ExHentai 多站点切换
- [x] Hero 过渡动画
- [x] 单元测试 + BLoC 测试（25 个用例）

## 环境要求

- Flutter 3.13.0–3.16.x
- Dart 3.1.0+
- Android Studio / VS Code
- (iOS 编译) macOS 或 GitHub Actions

## 快速开始

```bash
# 1. 克隆项目
git clone https://github.com/aaa142857/OViewer.git
cd OViewer

# 2. 安装依赖
flutter pub get

# 3. 生成 drift 数据库代码
dart run build_runner build --delete-conflicting-outputs

# 4. 运行 (Android 模拟器 / 真机)
flutter run

# 5. 运行测试
flutter test

# 6. 静态分析
flutter analyze
```

## 构建

### Android APK

```bash
flutter build apk --release
```

产物路径：`build/app/outputs/flutter-apk/app-release.apk`

### iOS IPA（需要 macOS）

```bash
flutter build ios --release --no-codesign
```

### GitHub Actions 自动构建

项目包含两个 CI workflow，push 到 `main` 或打 `v*` tag 时自动触发：

| Workflow | 产物 | Runner |
|----------|------|--------|
| `build_android.yml` | `app-release.apk` | ubuntu-latest |
| `build_ios.yml` | `OViewer.ipa` (unsigned) | macos-14 / Xcode 15.4 |

**手动触发**：Actions → 选择 workflow → Run workflow

**发布 Release**：
```bash
git tag v1.0.0
git push origin v1.0.0
```
打 tag 后自动构建并上传产物到 GitHub Releases。

### iOS 安装方式（未签名 IPA）

1. **AltStore** — 推荐，使用 Apple ID 自签名
2. **Sideloadly** — GUI 自签工具
3. **TrollStore** — 如果设备支持（iOS 14.0–16.6.1）

## iOS 12 兼容性

- Flutter 3.13.9–3.16.x（项目当前版本线）
- `flutter_inappwebview` 锁定 `^5.8.0`（6.x 需要 iOS 13+）
- 不使用 Firebase（需要 iOS 13+）
- Podfile 强制所有 Pod 部署目标为 `12.0`
- 所有依赖包均验证兼容 iOS 12

## 许可证

Apache License 2.0
