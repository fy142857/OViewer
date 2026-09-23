# OViewer

**[中文](README.md)** / [English](README.en.md)

OViewer（Old Viewer）是一款使用 Flutter 开发的 Android / iOS 漫画阅读器，支持 E-Hentai 与 ExHentai，提供画廊浏览、标签搜索、收藏管理和多种阅读模式。

项目最低系统目标为 **Android 5.0 和 iOS 12.0**，兼顾较旧设备的使用需求。

## 浏览与发现

- 浏览最新、热门画廊，以及自己的收藏和阅读历史。
- 首页和搜索页均支持列表 / 卡片视图切换；卡片按屏幕宽度自适应排列，封面保持竖版比例。
- 使用关键词、分类和最低评分筛选查找漫画。
- 输入时优先显示匹配的搜索历史，再提供标签联想。
- 支持中文标签翻译、多词标签和标签别名搜索。
- 从详情页查看相似画廊，或点击标签继续探索。
- 直接粘贴画廊链接，打开对应详情。

画廊详情页展示封面、上传者、语言、页数、标签和缩略图，并提供评分、评论及评论投票功能。

## 按习惯阅读

支持**从左到右、从右到左翻页，以及上下连续滚动**。

你可以缩放图片，通过进度条或缩略图快速跳页。点击预览图会从对应页开始阅读，普通阅读入口则恢复上次进度。

单击阅读画面即可显示或隐藏工具栏与状态栏。图片按需加载，成功加载后保留缓存，方便再次打开；退出阅读器会停止未完成的图片加载，加载失败时可以点击重试。

## 收藏与历史

登录后，可以管理云端收藏，并在列表和网格中通过**红色爱心**识别已收藏的漫画。

同一账号在其他设备收藏或取消收藏后，下拉刷新当前列表即可更新标记。

浏览历史与阅读进度保存在当前设备，方便继续阅读。阅读进度暂不支持跨设备同步。

## 账号与个性化

- 支持网页登录和手动输入 Cookie。
- 支持切换 E-Hentai / ExHentai，访问范围取决于账号权限。
- 提供中文和 English 界面。
- 支持浅色、深色和跟随系统主题。
- 可以设置默认阅读模式、配置代理和清理图片缓存。
- “我的标签”“标题语言”和“图片尺寸”会打开当前站点的对应设置页面。

## 下载与安装

在项目的 [Releases](https://github.com/fy142857/OViewer/releases) 或 [Actions](https://github.com/fy142857/OViewer/actions) 页面查找安装包：

| 平台 | 安装包 | 安装说明 |
|------|--------|----------|
| Android | APK | 下载后安装 |
| iOS | 未签名 IPA | 需要自行完成适用于设备的签名与安装流程 |

Releases 用于获取已发布版本；Actions 中可查看开发分支的构建产物。

## 当前限制

- 下载与离线阅读功能仍在完善中，目前建议以在线阅读为主。
- 浏览历史和阅读进度尚不支持跨设备同步。
- “缓存大小上限”目前仅保存设置值，尚未实现按该容量自动清理；可以手动清理图片缓存。
- iOS 12 是项目部署目标，实际兼容性仍需结合设备验证。

## 技术架构

OViewer 使用 Flutter 构建 Android 和 iOS 应用，将界面展示、状态管理和数据访问分层组织。页面通过 BLoC 管理交互状态，Repository 负责访问站点和本地存储。

搜索页面各自维护独立状态，避免相似画廊搜索覆盖原列表。阅读器按需获取资源，并区分已完成的缓存与尚未完成的请求，以减少重复加载。

### 技术栈

| 类别 | 选型 |
|------|------|
| 框架 | Flutter `>=3.13.0 <3.17.0` / Dart `>=3.1.0 <4.0.0` |
| 状态管理 | flutter_bloc 8.x + equatable |
| 依赖注入 | get_it |
| 网络请求 | dio、http、cookie_jar |
| 数据解析 | html，将站点页面解析为应用数据模型 |
| 本地存储 | drift（SQLite）+ shared_preferences |
| 图片与缓存 | cached_network_image + flutter_cache_manager |
| 阅读交互 | photo_view + scrollable_positioned_list |
| 登录与站点设置 | flutter_inappwebview 5.8.x |
| 自动构建 | GitHub Actions，生成 Android APK 和未签名 iOS IPA |

当前自动构建使用 Flutter 3.16.0。中文标签翻译来自 **EhTagTranslation**。

### 项目结构

```text
lib/
├── main.dart                    # 应用初始化与依赖注册
├── app.dart                     # 应用配置、主题与全局状态
├── core/
│   ├── constants/               # 站点地址、接口与应用常量
│   ├── l10n/                    # 中文 / English 界面文案
│   ├── network/                 # 网络请求、Cookie、代理与图片加载
│   ├── parser/                  # 画廊、搜索、标签与评论解析
│   ├── router/                  # 页面路由与生命周期观察
│   ├── storage/                 # 数据库、偏好设置与阅读索引缓存
│   ├── theme/                   # 主题与颜色
│   └── utils/                   # 链接、标题、标签查询与联想处理
├── models/                      # 数据模型
├── repositories/                # 网络与本地数据访问
├── blocs/                       # 浏览、搜索、阅读、收藏等状态管理
├── widgets/                     # 卡片、缩略图、评分等复用组件
└── screens/                     # 页面
    ├── home/                    # 首页
    ├── search/                  # 搜索
    ├── gallery_detail/          # 画廊详情
    ├── thumbnail_preview/       # 缩略图预览
    ├── reader/                  # 阅读器
    ├── favorites/               # 收藏
    ├── history/                 # 浏览历史
    ├── comments/                # 评论
    ├── download/                # 下载管理
    ├── login/                   # 登录
    └── settings/                # 应用与站点设置

android/                         # Android 平台工程
ios/                             # iOS 平台工程
test/                            # 单元测试与组件回归测试
.github/workflows/               # Android / iOS 自动构建
```

## 反馈与参与

遇到问题或有功能建议，欢迎提交 [Issue](https://github.com/fy142857/OViewer/issues)，也欢迎通过 Pull Request 参与改进。

反馈问题时，请尽量提供应用版本、设备与系统版本，以及复现步骤。截图中请遮挡账号、Cookie 等敏感信息。

## 开源许可

本项目采用 **Apache License 2.0**。

## 特别鸣谢

感谢 [EhTagTranslation/Database](https://github.com/EhTagTranslation/Database) 提供标签（Tag）中文翻译数据。
