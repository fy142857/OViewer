# O
Viewer 漫画阅读器 — 技术架构 · 需求文档 · 依赖清单

> **技术栈**: Flutter 3.16.0 / Dart | **最低部署目标**: iOS 11.0  
> **参照项目**: [EhPanda](https://github.com/EhPanda-Team/EhPanda)（SwiftUI + TCA）  
> **开发环境**: Windows 11 + Android Studio | **编译**: GitHub Actions (macOS runner)

---

## 第一部分：EhPanda 功能拆解与优先级映射

### 1.1 EhPanda 功能模块总览

EhPanda 作为一款成熟的 E-Hentai iOS 客户端，包含以下核心功能模块：

| # | 功能模块 | EhPanda 实现 | 说明 |
|---|---------|-------------|------|
| 1 | 画廊列表（首页） | 瀑布流/列表展示，支持 Popular / Watched / Favorites 等多分类 | 分页加载，下拉刷新 |
| 2 | 搜索系统 | 支持关键词搜索、分类筛选、高级搜索语法 | 搜索历史、搜索建议 |
| 3 | 画廊详情 | 封面、标题、标签、评分、评论、缩略图预览 | 元数据完整展示 |
| 4 | 漫画阅读器 | 左右滑动 / 上下滚动 / 双页模式，支持缩放 | 核心体验模块 |
| 5 | 收藏管理 | 多收藏夹分类，云端同步（需登录） | 支持增删改 |
| 6 | 浏览历史 | 本地记录已浏览画廊及阅读进度 | 自动记录 |
| 7 | 用户登录 | Cookie-based 登录（WebView 注入或手动输入） | E-Hentai 账户体系 |
| 8 | 标签系统 | 标签翻译（多语言）、标签筛选、标签跳转 | 支持 EhTagTranslation |
| 9 | 下载管理 | 后台下载画廊图片到本地，断点续传 | 队列管理 |
| 10 | 设置中心 | 主题切换、阅读器偏好、缓存管理、代理配置 | 持久化存储 |
| 11 | 画廊评分 | 对画廊进行评分 | 需要登录 |
| 12 | 评论系统 | 查看/发表评论，投票 | 需要登录 |
| 13 | Torrent 查看 | 查看画廊关联的种子信息 | 信息展示 |
| 14 | 归档下载 | 请求 E-Hentai 归档服务 | 需要 GP/Credits |
| 15 | 多站点切换 | E-Hentai / ExHentai 切换 | 需不同 Cookie |
| 16 | 快速翻页 | 阅读器内拖动滑块快速跳页 | 缩略图预览 |

### 1.2 优先级映射（OViewer）

#### P0 — MVP 核心（必须实现）

| 功能 | 说明 | 对应 EhPanda 模块 |
|-----|------|-----------------|
| 画廊浏览 | 首页列表/瀑布流，分页加载 | #1 |
| 搜索 | 关键词搜索 + 分类筛选 | #2 |
| 画廊详情 | 封面、元信息、标签、缩略图 | #3 |
| 漫画阅读器 | 左右翻页、上下滚动、双击缩放 | #4 |
| 收藏管理 | 本地收藏夹 + 云端收藏（登录后） | #5 |
| 浏览历史 | 自动记录浏览/阅读进度 | #6 |
| 用户登录 | Cookie 登录方式 | #7 |

#### P1 — 重要功能（第二阶段）

| 功能 | 说明 | 对应 EhPanda 模块 |
|-----|------|-----------------|
| 标签翻译 | 集成 EhTagTranslation 数据 | #8 |
| 下载管理 | 图片离线下载，队列控制 | #9 |
| 设置中心 | 主题、缓存、代理、阅读偏好 | #10 |
| 快速翻页 | 滑块 + 缩略图预览 | #16 |

#### P2 — 锦上添花（第三阶段）

| 功能 | 说明 | 对应 EhPanda 模块 |
|-----|------|-----------------|
| 评分 / 评论 | 画廊评分、评论交互 | #11, #12 |
| Torrent / 归档 | 信息查看 | #13, #14 |
| 多站点切换 | E-Hentai / ExHentai | #15 |

---

## 第二部分：技术架构设计

### 2.1 架构模式：EhPanda TCA → Flutter BLoC 映射

EhPanda 采用 SwiftUI + TCA（The Composable Architecture），其核心是**单向数据流**。在 Flutter 中，BLoC（Business Logic Component）是最接近的等价架构，两者的数据流如下对应：

```
┌─────────────────────────────────────────────────────────┐
│  EhPanda (TCA)              OViewer (BLoC)              │
│                                                         │
│  View ──dispatch──▶ Action   Widget ──add──▶ Event      │
│    │                  │        │                │        │
│    │                  ▼        │                ▼        │
│    │              Reducer      │             BLoC        │
│    │                  │        │          (mapEventToState)│
│    │                  ▼        │                │        │
│    │              Effect       │            Repository   │
│    │             (Side Effect) │           (Side Effect)  │
│    │                  │        │                │        │
│    │                  ▼        │                ▼        │
│    ◀──render──── State         ◀──rebuild── State        │
└─────────────────────────────────────────────────────────┘
```

两者都遵循 **State → View → Action/Event → Logic → Effect → New State** 的闭环。

### 2.2 项目目录结构

```
oviewer/
├── lib/
│   ├── main.dart                          # 应用入口
│   ├── app.dart                           # MaterialApp 配置、路由、主题
│   │
│   ├── core/                              # 核心基础设施
│   │   ├── constants/
│   │   │   ├── app_constants.dart         # 全局常量（baseUrl, 分页大小等）
│   │   │   └── api_endpoints.dart         # API 路径定义
│   │   ├── network/
│   │   │   ├── dio_client.dart            # Dio 实例配置（拦截器、超时、代理）
│   │   │   ├── cookie_manager.dart        # Cookie 持久化管理
│   │   │   └── api_exception.dart         # 统一异常定义
│   │   ├── parser/
│   │   │   ├── gallery_list_parser.dart   # HTML → GalleryPreview 列表
│   │   │   ├── gallery_detail_parser.dart # HTML → GalleryDetail
│   │   │   ├── gallery_image_parser.dart  # HTML → 图片 URL
│   │   │   └── search_parser.dart         # 搜索结果解析
│   │   ├── storage/
│   │   │   ├── local_storage.dart         # shared_preferences 封装
│   │   │   └── database.dart              # SQLite (drift) 初始化
│   │   ├── router/
│   │   │   └── app_router.dart            # 路由表定义
│   │   └── theme/
│   │       ├── app_theme.dart             # 亮色/暗色主题
│   │       └── app_colors.dart            # 颜色常量
│   │
│   ├── models/                            # 数据模型
│   │   ├── gallery_preview.dart           # 列表项模型
│   │   ├── gallery_detail.dart            # 详情模型
│   │   ├── gallery_image.dart             # 图片模型
│   │   ├── gallery_tag.dart               # 标签模型
│   │   ├── gallery_comment.dart           # 评论模型
│   │   ├── search_filter.dart             # 搜索筛选条件
│   │   ├── user_profile.dart              # 用户信息
│   │   ├── download_task.dart             # 下载任务
│   │   └── reading_progress.dart          # 阅读进度
│   │
│   ├── repositories/                      # 数据仓库层（BLoC 的数据源）
│   │   ├── gallery_repository.dart        # 画廊数据获取（网络 + 解析）
│   │   ├── search_repository.dart         # 搜索请求
│   │   ├── favorites_repository.dart      # 收藏操作
│   │   ├── history_repository.dart        # 浏览历史（本地数据库）
│   │   ├── auth_repository.dart           # 登录/Cookie 管理
│   │   ├── download_repository.dart       # 下载管理
│   │   ├── settings_repository.dart       # 设置持久化
│   │   └── tag_translation_repository.dart # 标签翻译数据
│   │
│   ├── blocs/                             # BLoC 状态管理
│   │   ├── gallery_list/
│   │   │   ├── gallery_list_bloc.dart     # 画廊列表业务逻辑
│   │   │   ├── gallery_list_event.dart    # 事件定义
│   │   │   └── gallery_list_state.dart    # 状态定义
│   │   ├── gallery_detail/
│   │   │   ├── gallery_detail_bloc.dart
│   │   │   ├── gallery_detail_event.dart
│   │   │   └── gallery_detail_state.dart
│   │   ├── reader/
│   │   │   ├── reader_bloc.dart           # 阅读器核心逻辑
│   │   │   ├── reader_event.dart
│   │   │   └── reader_state.dart
│   │   ├── search/
│   │   │   ├── search_bloc.dart
│   │   │   ├── search_event.dart
│   │   │   └── search_state.dart
│   │   ├── auth/
│   │   │   ├── auth_bloc.dart
│   │   │   ├── auth_event.dart
│   │   │   └── auth_state.dart
│   │   ├── favorites/
│   │   │   ├── favorites_bloc.dart
│   │   │   ├── favorites_event.dart
│   │   │   └── favorites_state.dart
│   │   ├── history/
│   │   │   └── ...
│   │   ├── download/
│   │   │   └── ...
│   │   └── settings/
│   │       └── ...
│   │
│   ├── widgets/                           # 可复用 UI 组件
│   │   ├── gallery_card.dart              # 画廊卡片（列表项）
│   │   ├── gallery_grid_item.dart         # 瀑布流项
│   │   ├── tag_chip.dart                  # 标签标签
│   │   ├── rating_bar.dart                # 评分条
│   │   ├── loading_indicator.dart         # 加载指示器
│   │   ├── error_widget.dart              # 错误提示组件
│   │   ├── cached_network_image.dart      # 图片缓存封装
│   │   └── thumbnail_grid.dart            # 缩略图网格
│   │
│   └── screens/                           # 页面
│       ├── home/
│       │   └── home_screen.dart           # 首页（Tab 布局: Popular/Watched/Favorites）
│       ├── gallery_detail/
│       │   └── gallery_detail_screen.dart # 画廊详情页
│       ├── reader/
│       │   └── reader_screen.dart         # 漫画阅读器页
│       ├── search/
│       │   └── search_screen.dart         # 搜索页
│       ├── favorites/
│       │   └── favorites_screen.dart      # 收藏管理页
│       ├── history/
│       │   └── history_screen.dart        # 浏览历史页
│       ├── login/
│       │   └── login_screen.dart          # 登录页
│       ├── download/
│       │   └── download_screen.dart       # 下载管理页
│       └── settings/
│           └── settings_screen.dart       # 设置页
│
├── ios/                                   # iOS 工程（GitHub Actions 编译）
│   ├── Podfile                            # platform :ios, '11.0'
│   └── Runner/
│       └── Info.plist
│
├── android/                               # Android 工程（本地调试用）
├── pubspec.yaml                           # 依赖声明
├── .github/
│   └── workflows/
│       └── build_ios.yml                  # GitHub Actions IPA 编译
└── README.md
```

### 2.3 核心流程时序设计

#### 流程 A：画廊列表加载

```
HomeScreen          GalleryListBloc         GalleryRepository       DioClient          Parser
    │                     │                        │                    │                  │
    │  FetchGalleries     │                        │                    │                  │
    │────────────────────▶│                        │                    │                  │
    │                     │  fetchGalleryList(page)│                    │                  │
    │                     │───────────────────────▶│                    │                  │
    │                     │                        │  GET /             │                  │
    │                     │                        │───────────────────▶│                  │
    │                     │                        │    HTML Response   │                  │
    │                     │                        │◀───────────────────│                  │
    │                     │                        │                    │                  │
    │                     │                        │  parseGalleryList(html)               │
    │                     │                        │─────────────────────────────────────▶ │
    │                     │                        │    List<GalleryPreview>               │
    │                     │                        │◀──────────────────────────────────── │
    │                     │   List<GalleryPreview>  │                    │                  │
    │                     │◀───────────────────────│                    │                  │
    │                     │                        │                    │                  │
    │  emit(GalleryListLoaded)                     │                    │                  │
    │◀────────────────────│                        │                    │                  │
    │  rebuild UI         │                        │                    │                  │
```

#### 流程 B：阅读器图片加载

```
ReaderScreen         ReaderBloc           GalleryRepository        DioClient          Parser
    │                    │                       │                     │                  │
    │  LoadImages(gid)   │                       │                     │                  │
    │───────────────────▶│                       │                     │                  │
    │                    │  fetchImagePage(gid,p) │                     │                  │
    │                    │──────────────────────▶ │                     │                  │
    │                    │                       │  GET /s/{token}/{gid}-{p}              │
    │                    │                       │────────────────────▶ │                  │
    │                    │                       │    HTML Response     │                  │
    │                    │                       │◀────────────────────│                  │
    │                    │                       │  parseImageUrl(html) │                  │
    │                    │                       │──────────────────────────────────────▶ │
    │                    │                       │    imageUrl (String) │                  │
    │                    │                       │◀─────────────────────────────────────│  │
    │                    │   GalleryImage          │                     │                  │
    │                    │◀──────────────────────│                     │                  │
    │                    │                       │                     │                  │
    │  emit(ImageLoaded) │                       │                     │                  │
    │◀───────────────────│                       │                     │                  │
    │  显示图片 + 预加载相邻页                     │                     │                  │
```

**关键设计要点**:
- 阅读器采用**预加载策略**：当前页加载完成后，自动预加载前后各 2-3 页的图片 URL 和缩略图
- 图片 URL 有时效性，解析后应立即使用或短时间缓存
- 大图使用渐进加载：先显示缩略图，再替换为原图

#### 流程 C：Cookie 登录

```
LoginScreen          AuthBloc             AuthRepository          WebView/Manual
    │                    │                      │                       │
    │  LoginRequested    │                      │                       │
    │───────────────────▶│                      │                       │
    │                    │                      │                       │
    │  ┌─── 方式一：WebView 登录 ───┐            │                       │
    │  │ openLoginWebView()         │           │                       │
    │  │                            │           │                       │
    │  │  用户在 WebView 完成登录    │           │                       │
    │  │  提取 Cookie (ipb_member_id, │          │                       │
    │  │  ipb_pass_hash, igneous)   │           │                       │
    │  └────────────────────────────┘           │                       │
    │                    │                      │                       │
    │  ┌─── 方式二：手动输入 Cookie ──┐           │                       │
    │  │  用户粘贴 Cookie 字符串     │           │                       │
    │  └──────────────────────────── ┘          │                       │
    │                    │                      │                       │
    │                    │  saveCookies(cookies) │                       │
    │                    │─────────────────────▶ │                       │
    │                    │                      │  持久化到 CookieJar    │
    │                    │                      │  写入 Dio CookieManager│
    │                    │                      │                       │
    │                    │  validateLogin()      │                       │
    │                    │─────────────────────▶ │                       │
    │                    │                      │  GET /uconfig.php     │
    │                    │                      │  检查返回是否为登录态   │
    │                    │                      │                       │
    │                    │  LoginSuccess / Fail  │                       │
    │                    │◀─────────────────────│                       │
    │  emit(Authenticated)                      │                       │
    │◀───────────────────│                      │                       │
```

### 2.4 数据模型定义

```dart
// ========== gallery_preview.dart ==========
class GalleryPreview {
  final int gid;              // 画廊 ID
  final String token;         // 画廊 Token
  final String title;         // 标题（日文/英文）
  final String? titleJpn;     // 日文标题
  final String thumbUrl;      // 封面缩略图 URL
  final String category;      // 分类 (Doujinshi, Manga, etc.)
  final double rating;        // 评分 (0.0 ~ 5.0)
  final String uploader;      // 上传者
  final int fileCount;        // 图片数量
  final int fileSize;         // 文件大小 (bytes)
  final DateTime postedAt;    // 发布时间
  final List<String> tags;    // 简化标签列表（预览用）
}

// ========== gallery_detail.dart ==========
class GalleryDetail {
  final int gid;
  final String token;
  final String title;
  final String? titleJpn;
  final String thumbUrl;
  final String category;
  final String uploader;
  final DateTime postedAt;
  final String? parent;       // 父画廊 ID
  final bool visible;
  final String language;
  final int fileCount;
  final int fileSize;
  final double rating;
  final int ratingCount;      // 评分人数
  final int favoriteCount;    // 收藏数
  final int? favoritedSlot;   // 当前用户收藏夹编号 (null = 未收藏)
  final List<GalleryTag> tags;         // 完整标签列表（按命名空间分组）
  final List<GalleryComment> comments; // 评论
  final List<String> thumbnailUrls;    // 缩略图列表
  final String? archiveUrl;            // 归档下载 URL
}

// ========== gallery_tag.dart ==========
class GalleryTag {
  final String namespace;     // 命名空间 (artist, female, male, parody, etc.)
  final String key;           // 标签原文
  final String? translation;  // 翻译文本 (来自 EhTagTranslation)
  final bool isUpvoted;       // 当前用户是否赞过
  final bool isDownvoted;     // 当前用户是否踩过
}

// ========== gallery_image.dart ==========
class GalleryImage {
  final int index;            // 页码 (从 0 开始)
  final String pageUrl;       // 图片页面 URL (/s/...)
  final String imageUrl;      // 实际图片 URL
  final String? thumbUrl;     // 缩略图 URL
  final int width;
  final int height;
}

// ========== gallery_comment.dart ==========
class GalleryComment {
  final int id;
  final String author;
  final DateTime postedAt;
  final String content;       // HTML 内容
  final int score;
  final bool isUploader;      // 是否是上传者评论
  final bool isVotedUp;
  final bool isVotedDown;
}

// ========== search_filter.dart ==========
class SearchFilter {
  final String? keyword;
  final List<String> categories;  // 勾选的分类
  final int? minRating;           // 最低评分筛选
  final int? minPages;
  final int? maxPages;
  final bool searchGalleryName;
  final bool searchGalleryTags;
  final bool searchGalleryDesc;
  final bool searchLowPowerTags;
}

// ========== reading_progress.dart ==========
class ReadingProgress {
  final int gid;
  final int lastReadPage;     // 最后阅读页码
  final int totalPages;
  final DateTime lastReadAt;
}

// ========== download_task.dart ==========
class DownloadTask {
  final int gid;
  final String token;
  final String title;
  final String thumbUrl;
  final int totalPages;
  final int downloadedPages;
  final DownloadStatus status;  // pending, downloading, paused, completed, failed
  final DateTime createdAt;
}
```

### 2.5 架构分层职责

| 层 | 职责 | 技术选型 |
|---|------|---------|
| **Screen (页面)** | UI 布局、用户交互、监听 BLoC State 重建 | Flutter Widget + BlocBuilder/BlocListener |
| **Widget (组件)** | 可复用的 UI 片段 | StatelessWidget / StatefulWidget |
| **BLoC (业务逻辑)** | 接收 Event → 调用 Repository → emit State | flutter_bloc |
| **Repository (仓库)** | 数据获取/缓存策略的统一入口 | 纯 Dart 类 |
| **Network (网络)** | HTTP 请求、Cookie 管理 | dio + cookie_jar |
| **Parser (解析)** | HTML → Model 的转换 | html (Dart 包) |
| **Storage (存储)** | 本地持久化 | shared_preferences + drift (SQLite) |

---

## 第三部分：兼容 iOS 11 的依赖清单

### 3.1 依赖总览

> **核心原则**：优先选择纯 Dart 包（天然无 iOS 版本限制），含原生代码的包需验证 Podspec 中 `IPHONEOS_DEPLOYMENT_TARGET ≤ 11.0`。

#### 状态管理 & 架构

| 包名 | 版本约束 | 类型 | iOS 兼容性 | 说明 |
|------|---------|------|-----------|------|
| `flutter_bloc` | `^8.1.3` | 纯 Dart | ✅ 无限制 | BLoC 状态管理 |
| `equatable` | `^2.0.5` | 纯 Dart | ✅ 无限制 | State/Event 值比较 |
| `get_it` | `^7.6.4` | 纯 Dart | ✅ 无限制 | 依赖注入 / Service Locator |

#### 网络 & 数据获取

| 包名 | 版本约束 | 类型 | iOS 兼容性 | 说明 |
|------|---------|------|-----------|------|
| `dio` | `^5.3.4` | 纯 Dart | ✅ 无限制 | HTTP 客户端 |
| `cookie_jar` | `^4.0.8` | 纯 Dart | ✅ 无限制 | Cookie 管理 |
| `dio_cookie_manager` | `^3.1.1` | 纯 Dart | ✅ 无限制 | Dio Cookie 拦截器 |
| `html` | `^0.15.4` | 纯 Dart | ✅ 无限制 | HTML 解析（替代原生 WebKit） |
| `connectivity_plus` | `^5.0.2` | 含原生 | ✅ iOS 11+ | 网络连接状态检测 |

#### 图片 & 缓存

| 包名 | 版本约束 | 类型 | iOS 兼容性 | 说明 |
|------|---------|------|-----------|------|
| `cached_network_image` | `^3.3.0` | 含原生 | ✅ iOS 11+ | 图片缓存与占位符 |
| `flutter_cache_manager` | `^3.3.1` | 含原生 | ✅ iOS 11+ | 通用文件缓存 |
| `photo_view` | `^0.14.0` | 纯 Dart | ✅ 无限制 | 图片缩放/平移手势 |
| `extended_image` | `^8.2.0` | 含原生 | ✅ iOS 11+ | 高级图片组件（可选替代 cached_network_image） |

#### 本地存储

| 包名 | 版本约束 | 类型 | iOS 兼容性 | 说明 |
|------|---------|------|-----------|------|
| `shared_preferences` | `^2.2.2` | 含原生 | ✅ iOS 11+ | 轻量 KV 存储（设置/Cookie） |
| `drift` | `^2.13.0` | 纯 Dart | ✅ 无限制 | SQLite ORM（历史/下载记录） |
| `sqlite3_flutter_libs` | `^0.5.18` | 含原生 | ✅ iOS 11+ | SQLite 原生库 |
| `path_provider` | `^2.1.1` | 含原生 | ✅ iOS 11+ | 获取应用目录路径 |
| `path` | `^1.8.3` | 纯 Dart | ✅ 无限制 | 路径处理 |

#### UI & 阅读器

| 包名 | 版本约束 | 类型 | iOS 兼容性 | 说明 |
|------|---------|------|-----------|------|
| `flutter_staggered_grid_view` | `^0.7.0` | 纯 Dart | ✅ 无限制 | 瀑布流布局 |
| `pull_to_refresh` | `^2.0.0` | 纯 Dart | ✅ 无限制 | 下拉刷新/上拉加载 |
| `scrollable_positioned_list` | `^0.3.8` | 纯 Dart | ✅ 无限制 | 可定位滚动列表（阅读器用） |
| `shimmer` | `^3.0.0` | 纯 Dart | ✅ 无限制 | 骨架屏加载效果 |
| `flutter_slidable` | `^3.0.1` | 纯 Dart | ✅ 无限制 | 列表项滑动操作（删除/收藏） |
| `badges` | `^3.1.2` | 纯 Dart | ✅ 无限制 | 角标 |

#### WebView（登录用）

| 包名 | 版本约束 | 类型 | iOS 兼容性 | 说明 |
|------|---------|------|-----------|------|
| `flutter_inappwebview` | **`^5.8.0`** | 含原生 | ✅ iOS 9+ | ⚠️ **必须锁定 5.x！6.x 需要 iOS 13+** |

#### 工具类

| 包名 | 版本约束 | 类型 | iOS 兼容性 | 说明 |
|------|---------|------|-----------|------|
| `intl` | `^0.18.1` | 纯 Dart | ✅ 无限制 | 国际化/日期格式化 |
| `url_launcher` | `^6.2.1` | 含原生 | ✅ iOS 11+ | 打开外部链接 |
| `share_plus` | `^7.2.1` | 含原生 | ✅ iOS 11+ | 系统分享 |
| `package_info_plus` | `^5.0.1` | 含原生 | ✅ iOS 11+ | 获取应用版本号 |
| `permission_handler` | `^11.0.1` | 含原生 | ✅ iOS 11+ | 权限请求 |
| `logger` | `^2.0.2` | 纯 Dart | ✅ 无限制 | 日志工具 |

### 3.2 危险依赖 — 不兼容 iOS 11，需避免或替代

| 包名 | 最低 iOS 要求 | 替代方案 |
|------|-------------|---------|
| `firebase_core` 及 Firebase 全家桶 | iOS 13+ | 不使用 Firebase；推送用 APNs 直接对接或放弃 |
| `flutter_inappwebview ^6.x` | iOS 13+ | **锁定 `^5.8.0`** |
| `local_auth` | iOS 12+ | 使用 PIN/密码锁或暂不支持生物识别 |
| `google_sign_in` | iOS 12+ | 不使用 Google 登录，Cookie 登录即可 |
| `flutter_local_notifications` | iOS 12+ | 使用 `flutter_local_notifications ^14.x`（检查旧版）或放弃本地通知 |
| `geolocator` | iOS 12+ | 漫画阅读器不需要定位 |
| `webview_flutter ^4.x` | iOS 12+ | 使用 `flutter_inappwebview ^5.8.0` 替代 |
| `in_app_purchase` | iOS 12+ | 不涉及内购 |

### 3.3 pubspec.yaml 参考

```yaml
name: oviewer
description: A manga viewer app for E-Hentai
version: 1.0.0+1

environment:
  sdk: '>=3.0.0 <4.0.0'   # Flutter 3.16.0 对应 Dart 3.2.x
  flutter: '>=3.16.0'

dependencies:
  flutter:
    sdk: flutter

  # 状态管理
  flutter_bloc: ^8.1.3
  equatable: ^2.0.5
  get_it: ^7.6.4

  # 网络
  dio: ^5.3.4
  cookie_jar: ^4.0.8
  dio_cookie_manager: ^3.1.1
  html: ^0.15.4
  connectivity_plus: ^5.0.2

  # 图片
  cached_network_image: ^3.3.0
  flutter_cache_manager: ^3.3.1
  photo_view: ^0.14.0

  # 本地存储
  shared_preferences: ^2.2.2
  drift: ^2.13.0
  sqlite3_flutter_libs: ^0.5.18
  path_provider: ^2.1.1
  path: ^1.8.3

  # UI
  flutter_staggered_grid_view: ^0.7.0
  pull_to_refresh: ^2.0.0
  scrollable_positioned_list: ^0.3.8
  shimmer: ^3.0.0
  flutter_slidable: ^3.0.1
  badges: ^3.1.2

  # WebView (登录)
  flutter_inappwebview: ^5.8.0   # ⚠️ 不能升级到 6.x

  # 工具
  intl: ^0.18.1
  url_launcher: ^6.2.1
  share_plus: ^7.2.1
  package_info_plus: ^5.0.1
  permission_handler: ^11.0.1
  logger: ^2.0.2

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^3.0.1
  build_runner: ^2.4.7
  drift_dev: ^2.13.0
  bloc_test: ^9.1.5
  mocktail: ^1.0.1

flutter:
  uses-material-design: true
```

### 3.4 iOS 工程配置要点

**ios/Podfile**（必须手动修改）：

```ruby
platform :ios, '11.0'

# Flutter 3.16 默认可能设为 12.0，需强制改回 11.0
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '11.0'
    end
  end
end
```

**ios/Runner.xcodeproj/project.pbxproj**：
搜索 `IPHONEOS_DEPLOYMENT_TARGET`，将所有值改为 `11.0`。

---

## 第四部分：功能需求规格说明

### FR-01: 画廊列表浏览

**描述**：用户打开应用后，首页以列表或瀑布流形式展示画廊。支持多个分类 Tab（Popular、Latest、Watched、Favorites），支持分页加载。

**验收标准**：
- 首页加载后 3 秒内显示首屏内容（含封面缩略图）
- 下拉刷新获取最新数据
- 上拉触底自动加载下一页
- 每项展示：封面、标题、分类标签、评分、图片数量
- 无网络时显示缓存数据或友好错误提示
- 支持列表/瀑布流视图切换

### FR-02: 搜索

**描述**：用户可通过关键词搜索画廊，支持分类筛选和高级搜索选项。

**验收标准**：
- 搜索框支持即时输入，回车触发搜索
- 搜索结果以与首页相同的列表形式展示
- 支持按分类勾选筛选（Doujinshi, Manga, Artist CG 等）
- 搜索历史本地保存，最近 20 条
- 空结果时显示提示信息
- 支持搜索建议（可选，基于标签自动补全）

### FR-03: 画廊详情

**描述**：用户点击画廊进入详情页，展示完整元数据。

**验收标准**：
- 显示大封面、标题（日文/英文）、分类、上传者、发布时间
- 标签按命名空间分组展示，可点击跳转搜索
- 显示评分（星级 + 数字）和收藏数
- 缩略图网格预览所有页面
- 「开始阅读」按钮（有历史时显示「继续阅读 第X页」）
- 收藏按钮（登录后可选收藏夹）
- 评论列表展示

### FR-04: 漫画阅读器

**描述**：核心阅读体验，支持多种阅读模式。

**验收标准**：
- 支持左右滑动翻页模式（默认）
- 支持上下滚动连续模式
- 双击/双指缩放图片
- 当前页/总页数指示器
- 点击屏幕中央显示/隐藏控制栏
- 控制栏包含：返回、页码滑块、阅读模式切换、设置
- 自动记录阅读进度
- 预加载相邻 2-3 页图片
- 图片加载失败时显示重试按钮
- 支持屏幕常亮

### FR-05: 收藏管理

**描述**：用户可收藏画廊到本地或云端收藏夹。

**验收标准**：
- 未登录：本地收藏，存储到 SQLite
- 已登录：云端收藏，同步到 E-Hentai 服务器
- 已登录时支持选择收藏夹编号（0-9）
- 收藏列表支持分页加载
- 支持取消收藏（滑动或长按）
- 收藏状态在详情页实时反映

### FR-06: 浏览历史

**描述**：自动记录用户浏览过的画廊和阅读进度。

**验收标准**：
- 每次打开画廊详情自动记录
- 每次翻页更新阅读进度
- 历史列表按时间倒序排列
- 显示阅读进度百分比
- 支持清除单条 / 全部历史
- 数据本地存储（SQLite）

### FR-07: 用户登录

**描述**：通过 Cookie 方式登录 E-Hentai 账户。

**验收标准**：
- 方式一：内置 WebView 打开 E-Hentai 登录页，登录后自动提取 Cookie
- 方式二：手动输入 Cookie（ipb_member_id, ipb_pass_hash, igneous）
- 登录后自动验证（请求个人页面检查状态）
- Cookie 持久化存储，应用重启后自动恢复
- 登录/登出状态全局同步
- 登录失败时显示明确错误信息

### 非功能需求

| 编号 | 类别 | 要求 |
|------|------|------|
| NFR-01 | 性能 | 首页列表滚动帧率 ≥ 55fps（iOS 11 设备上） |
| NFR-02 | 性能 | 阅读器翻页延迟 < 300ms（已缓存图片） |
| NFR-03 | 存储 | 图片缓存上限可配置（默认 500MB），超限 LRU 清理 |
| NFR-04 | 网络 | 支持 HTTP 代理配置（Socks5/HTTP），用于需要代理访问的网络环境 |
| NFR-05 | 兼容性 | 最低支持 iOS 11.0，在 iPhone 5s ~ iPhone 15 上正常运行 |
| NFR-06 | 安全 | Cookie 加密存储，不以明文写入日志 |
| NFR-07 | 国际化 | UI 支持中文/英文/日文（至少中英） |
| NFR-08 | 可维护性 | 代码覆盖率目标 ≥ 60%（BLoC 层 ≥ 80%） |
| NFR-09 | 离线体验 | 已下载的画廊在无网络时完全可读，已缓存的列表/详情离线可浏览 |

---

## 第五部分：开发路线图

### Phase 0 — 框架搭建（第 1-2 周）

- 初始化 Flutter 项目，配置 pubspec.yaml 依赖
- 搭建 BLoC 基础架构（get_it 注册、BlocProvider 层级）
- 配置 Dio 网络层（拦截器、Cookie 管理、错误处理）
- 实现 HTML 解析器骨架（GalleryListParser）
- 配置 drift 数据库 schema（历史、收藏、下载）
- 搭建 GitHub Actions iOS 编译流水线
- 实现基本路由和空白页面骨架

### Phase 1 — MVP 核心功能（第 3-6 周）

- **画廊列表**：首页 Tab 布局 + 分页加载 + 下拉刷新
- **搜索**：关键词搜索 + 分类筛选 + 搜索历史
- **画廊详情**：完整信息展示 + 缩略图网格
- **漫画阅读器**：左右翻页 + 上下滚动 + 缩放 + 预加载
- **Cookie 登录**：WebView 登录 + 手动输入
- **收藏**：本地收藏 + 云端收藏（登录后）
- **浏览历史**：自动记录 + 进度保存

### Phase 2 — 增强功能（第 7-10 周）

- **标签翻译**：集成 EhTagTranslation 数据源
- **下载管理**：后台下载 + 队列 + 断点续传
- **设置中心**：主题切换、缓存管理、代理配置、阅读偏好
- **阅读器增强**：快速翻页滑块 + 缩略图预览 + 双页模式
- **性能优化**：图片内存管理、列表回收、骨架屏

### Phase 3 — 完善与打磨（第 11-12 周）

- 评分 / 评论交互
- 多站点切换（E-Hentai / ExHentai）
- UI 动画打磨 & 适配不同屏幕尺寸
- 按改动影响选择单元测试与 Widget 回归；慢测试及 AI 开发规则以 [版本管理文档](docs/VERSION_MANAGEMENT.md#按改动选择测试与跳过慢测试) 为准，非必要不改阅读器、预加载、缓存或网络调度
- 性能 profiling & 优化（特别是 iOS 11 旧设备）
- 文档 & README 完善
