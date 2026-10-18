# 离线阅读器进入优化（Issue #63）

## 实现与边界

保留 Android 原有 300ms 缩放转场，关闭阅读路由的转场快照，避免异步加载页面被冻结在快照中。Android 立即退出、iOS 原生转场及侧滑返回保留。

入口解析、来源选择和错误提示统一为黑底。路由级 `ReaderPresentation` 管理系统栏，重复请求去重；首次全屏请求完成后等待两次稳定布局，连续窗口变化时最多等待 250ms。仅离线图片展示等待这一步，在线已有暖缓存仍可首帧显示。快速返回、路由被其他页面覆盖和恢复均按路由生命周期处理。

当前页的读取和 SHA-256 校验在来源确定后开始，与历史写入、全屏布局并行执行；历史写入顺序不变。`OfflineEntryRead` 只消费一次，并匹配书本、页码、路径、摘要和字节数，页面修订后不会复用旧结果。文件路径检查保留，实际读取和哈希在后台 isolate 完成。没有新增跨会话图片缓存、扩大内存预算、降低分辨率或迁移数据库。

首图显示前暂缓邻页读取，首图失败或退出也会释放等待；迟到资源不会回写已退出的阅读器。纵向离线图片加载时预留一屏高度，避免短小的进度圆圈让列表一次性构建并解码整本图片。实际图片继续按原始比例显示，缺页和修复保持离线语义。

## 测量方法

- 设备：Huawei VOG-AL10，Android 10 / API 29；本机 Flutter 3.13.9、Dart 3.1.5，arm64 Profile 构建。
- 基线：候选 `1.9.1+90` 源码，仅加入诊断；两版都使用相同独立包名 `com.oviewer.oviewer.offline_test`、签名、合成缓存数据和阅读模式。
- 数据：12 页、1200×1800 的确定性合成 PNG；详情及缩略图由本地 fixture 服务提供，不使用用户漫画或登录凭据。
- 入口：下载卡片、详情阅读按钮、详情缩略图、预览页、首页历史、独立历史页；横向、反向、纵向每种模式每个入口各 10 次，共 180 次。
- `READER_DIAGNOSTICS=true` 才输出匿名阶段耗时；正式构建默认关闭。记录入口、元数据、历史、系统栏、窗口尺寸、预读、解码、首图帧回调及 Flutter 构建/光栅耗时。
- 首图指标是资源可显示后的帧结束回调，不等同于摄像机测得的物理屏幕延迟。历史入口的最终诊断还覆盖跳转前查询；基线历史指标从路由创建开始，略低估基线的点击总耗时。
- 最终版按实际帧时间戳筛选首秒，并等待 Profile 批量回传；基线旧回调窗口可能漏掉延迟回传，因此不以两者的帧数量计算改善比例。

## 自动化验证

回归包括在线暖缓存首帧、三种离线阅读模式、显式非首页图片的坐标稳定性、页码恢复、进入途中返回、iOS 返回手势及取消手势、工具栏和系统栏切换、缓存修复和删除、缺页不联网、取消后不读取/回写、损坏摘要拒绝及 GIF 多帧播放。

## 真机结果（2026-10-19）

| 模式 | 基线首图中位数 ms | 修复后中位数 ms | 基线 P95 ms | 修复后 P95 ms |
|---|---:|---:|---:|---:|
| 横向 | 327.6 | 326.8 | 364.2 | 362.3 |
| 反向 | 328.0 | 324.6 | 374.4 | 349.6 |
| 纵向 | 1536.4 | 309.5 | 1599.2 | 334.6 |

基线 180 次进入有 179 次在 1.6 秒观察窗口内显示首图；1 次超时未显示，未纳入首图耗时分位数。修复后 180/180 次均显示首图，整体 P95 从 1579.9ms 降至 355.6ms。每个入口和模式均完整采集了 10 次。

最终版首秒构建/光栅帧耗时最大 30.7ms，超过 50ms 的帧为 0；首图出现后的首秒内窗口尺寸变化为 0。非首页图片的组件测试另外逐帧检查了图片顶部坐标，邻页解码期间没有超过 1px 的位移，页码保持不变。

完整 Flutter 回归 **758 项通过**，静态分析 **102 条诊断、无新增错误或警告**；独立验收脚本已完成编译与真机运行。iOS 原生返回与取消侧滑由组件测试覆盖，本次没有 iOS 真机性能数据。Android 设备没有可用的 `screenrecord` 命令，以上是应用侧时序、窗口指标和组件坐标验证，不是视频逐帧测量。

已删除本次创建的 `offline_test` 验收包，移除 8765 端口转发并停止本次 fixture 服务。手机原正式版仍为 1.9.0（82），安装路径及更新时间保持不变；原 Debug 版仍保留。

本地证据保存在忽略目录：`build/issue63-baseline-full.log`、`build/issue63-final-full.log`、`build/issue63-performance.json`、`build/issue63-final-full-tests.log`、`build/issue63-final-analysis.log`。基线 Profile APK SHA-256 为 `cb6c10d3131aa33cff0a1582ca329275b1ac78fb5106b68d0a789ca901d26ed6`；最终验收 APK 为 `ee6db602eb73c4cb032ea5b3a52ec4935b6f248bbf2ee5d5b44fecf61a6d8473`，仅用于独立测试包，不是正式发布安装包。


## 复测入口

`test_driver/reader_entry_benchmark.dart` 使用真实生产页面及其点击回调，具有独立包名检查。它只用于本地验收，不参与 Actions 产物上传。

启动 `python -m scripts.offline_fixture_server`，为验收设备设置 `adb -s <serial> reverse tcp:8765 tcp:8765`。在忽略的 `build/` 目录准备以下 Gradle 初始化脚本，避免改动应用的发布构建配置：

```groovy
allprojects { p ->
    p.afterEvaluate {
        if (p.path == ':app') {
            p.android.buildTypes.profile.applicationIdSuffix = '.offline_test'
            p.android.buildTypes.profile.manifestPlaceholders.appLabel = 'OViewer Offline Test'
        }
    }
}
```

在已有 Android/Flutter SDK 本地配置和依赖的工作区执行 `android/gradlew -p android :app:assembleProfile -I <脚本绝对路径> -Ptarget=<reader_entry_benchmark.dart绝对路径> -Ptarget-platform=android-arm64 -Pdart-defines=<READER_DIAGNOSTICS=true的Base64>`。安装前用 `aapt dump badging` 确认包名为 `com.oviewer.oviewer.offline_test`。Windows 若遇到 Java Unix socket 临时路径错误，可为当前命令设置 `JAVA_TOOL_OPTIONS=-Djdk.net.unixdomain.tmpdir=<已存在的短路径>`。

默认执行完整 180 次；短轮次可使用 Dart defines `BENCH_MODES=0,2`、`BENCH_ENTRIES=download`、`BENCH_SAMPLES=3`。日志须持续采集并在完成标记后保留两秒，不能只依赖 Android 的环形日志缓存。验收结束清理本次创建的测试包、端口转发和 fixture 服务，保留原有正式版及 Debug 版。


## 上一级页面位移的补充修复（2026-10-19）

后续反馈明确了另一个问题：进入、退出在线或离线阅读器时，移动的是上一级下载页或详情页。前面的首图耗时、阅读器内图片坐标验证不能证明父页面稳定。

回归用例复现了两个独立原因：Android 阅读器的默认转场会驱动上一页的 secondary animation（进入 50ms 时为 0.1667）；即使关闭这一联动，隐藏状态栏仍会使上一页标题从 y=42 移到 y=18，向上移动 24px。

补充修复仅取消 Android 上一级页面参与阅读器缩放，保留阅读器自身的 300ms 缩放和 iOS 原生转场。普通页面使用 `AppPageRoute`，在被阅读器覆盖时保留原有系统栏安全区，退出后等实际安全区恢复再接回实时数据。保护层始终保留相同组件结构，因此不会重建详情 Bloc、下载页状态或丢失滚动位置。只保留系统栏 padding/viewPadding，键盘、字体设置和实际旋转仍按实时配置布局，普通页面之间的转场也保持不变。

新增组件回归同时覆盖普通 AppBar 与详情页 SliverAppBar、非零滚动位置、延迟系统栏恢复、快速再次进入、页面状态身份、阅读器接收实时全屏数据，以及普通导航、键盘与旋转兼容性。完整 Flutter 回归 **761 项通过**，静态分析无新增错误或警告。

Android 真机使用独立 Profile 包，在下载页、已缓存漫画详情页、未缓存漫画详情页执行三种阅读模式、工具栏隐藏/显示两种退出状态，每组 3 次，共 **54 次进退、2712 帧**。所有标题和内容位置/尺寸偏差均为 **0.0 逻辑像素**，上一页 secondary animation 为 0，页面状态未重建。再用 **18 次进退、904 帧** 补查原生窗口尺寸与安全区恢复，尺寸没有变化，返回后父页面安全区均与系统实时数据一致。合计 **72 次进退、3616 帧**。

本轮直接测量上一级页面，未以“阅读器内部没有变化”替代父页面验收。证据位于 `build/reader-background-phone.log`、`build/reader-background-window.log`、`build/reader-background-validation.json`、`build/reader-background-tests.log` 和 `build/reader-background-full-tests.log`；复测入口为 `test_driver/reader_background_benchmark.dart`，沿用前述独立包名初始化脚本，可用 `BACKGROUND_REPEATS=1` 执行 18 次短轮次。Actions 产物、正式版包名及签名未改动。
