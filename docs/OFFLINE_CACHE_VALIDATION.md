# 离线缓存验收记录

验收日期：2026-10-13。按本次实施要求，Android 运行验收使用独立模拟器 `OViewer_Offline_API36`（Android 16 / API 36.1，`emulator-5556`）；测试包为 `com.oviewer.oviewer.offline_test`。未覆盖原应用，未操作手机中的正式版。样例内容为本机生成的 PNG、JPEG、GIF、WebP，不依赖真实站点账号或内容。

## 自动化覆盖

| 计划要求 | 对应验证 |
| --- | --- |
| 详情请求固定来源、未知/错误来源拒绝、登录页拒绝 | `offline_source_settings_test.dart` 检查请求发出后切站、错误 gid/token/域名、登录页和禁止重定向；下载创建接口强制显式 `OfflineKey` |
| EH/EX 独立身份与文件、完整索引 | `offline_storage_test.dart` 检查两站同 gid、索引缺页拒绝、完整内容登记 |
| 默认 2 本 / 4 张，设置范围与持久化 | `offline_source_settings_test.dart` 覆盖默认值、重启读取、错误类型/越界回退和写入失败；`offline_settings_widget_test.dart` 检查保存成功后才改变运行配置 |
| 全局并发、重复继续、取消和槽位释放 | `offline_coordinator_test.dart` 使用受控请求检查 3 本共享 1/6 张额度、1 本 / 1 张补下、降低限制时自然收尾、重复开始仅一个执行器、同步取消所有客户端 |
| 二进制原样保存、原子落盘、校验与恢复 | `offline_storage_test.dart` 覆盖四种格式原始字节、HTML/截断响应拒绝、取消后清理、登记失败回收、孤立文件清理、缺失文件恢复与路径边界 |
| 旧数据库与旧下载迁移 | `gallery_warning_persistence_test.dart` 检查 schema 升级；`offline_storage_test.dart` 检查旧来源待确认、验证后复用有效文件、保留待修复页和旧文件所有权 |
| 有限重试、认证/限额/磁盘错误 | `offline_coordinator_test.dart` 检查每页最多三次、失败不误报完成、401/509 和存储失败暂停且保留已落盘页面 |
| 重启手动继续、暂停原因保留 | 协调器冷启动测试检查不发请求；存储测试检查显式暂停原因不被覆盖 |
| 全部阅读入口优先本地 | `history_offline_entry_test.dart` 检查共享历史入口；`ReaderEntryScreen` 按来源解析本地书籍；模拟器验证下载页和主页历史 |
| 三种阅读模式、部分缓存、损坏提示 | `offline_reader_test.dart` 实际解码本地图片，检查三种模式不访问画廊接口、缺页操作菜单及末页定位 |
| 修复刷新、删除阅读会话 | 阅读器测试检查旧解码结果不能回写、目录更新、删除被管理页覆盖的阅读器时只移除对应阅读路由；协调器测试检查错误站点修复不破坏有效缓存 |
| Android 原生服务 | `OfflineDownloadServiceTest` 在 API 21/26/29/33/35 检查前台通知隐私、暂停入口、非自动重启、唤醒锁释放；API 35 检查系统超时停止 |
| iOS 生命周期 | 协调器测试检查后台取消、前台仅恢复后台暂停任务，手动暂停保持；冷启动测试覆盖进程重启不自动继续 |
| 原功能兼容 | 完整 Flutter 测试套件覆盖现有阅读器、代理、Cookie、更新及保存图片；Android 原生检查覆盖现有平台实现 |

## Android 模拟器运行证据

以下检查通过生产界面、调度器、数据库、文件存储与原生服务执行，只有站点 HTML/API 传输映射到本机样例服务器。

| 场景 | 实际结果 |
| --- | --- |
| 来源确认 | EH 与 EX 确认框分别显示实际来源、标题和总页数；确认前不创建下载任务 |
| 两站隔离 | EH 1001（12 页）与 EX 1001（12 页）同时存在、目录不同；EX 下载后原有 180 张 EH 页面记录未变，共 192 张图片逐一读取并核验 SHA-256 |
| 设置与并发 | 默认显示 2/4，可选范围分别为 1–3 和 1–6；改成 3/6 后偏好文件持久保存，实际下载峰值为 6 |
| 通知拒绝 | 拒绝通知权限后可继续下载，无反复请求或额外“系统未开启通知”弹窗 |
| 下载完整性 | 12 页完整样例逐文件与原始 PNG/JPEG/GIF/WebP 比较；错误索引任务保持未完成，修正来源后可以继续 |
| 断网冷启动 | 停止应用进程、关闭模拟器网络和样例响应后重启，从下载页和主页历史进入本地阅读；目录、GIF 动画、翻页和进度可用，阅读期间样例请求为零 |
| 保存图片 | 断网将第 12 页 WebP 保存至 MediaStore，类型为 `image/webp` |
| 普通缓存清理 | 清除图片缓存后，离线漫画和原有页面仍存在 |
| 后台下载 | 回到桌面后前台服务保持活动，图片继续落盘 |
| Activity 销毁/恢复 | 下载中从最近任务划掉应用；系统任务记录确认 Activity 已移除，服务仍为前台。重开后 PID、主 Dart isolate 和 Drift isolate 均与移除前一致 |
| 锁屏下载 | 屏幕保持 `Asleep` 时修复图片成功登记为完成；完成后服务停止，当前持有的离线唤醒锁释放 |
| 通知暂停 | 点击系统下载通知的 Pause 后服务停止，120 页任务保留 30 页，状态为用户暂停 |
| 部分缓存 | 从下载列表打开未完成任务，缺页显示 “Not cached yet” 和页面操作；不会自动发起图片请求 |
| 补下与进程终止 | 从 30 页继续只请求后续页面；强制停止时已存 36 页，冷启动恢复为暂停/中断，未自动请求目录或图片 |
| 系统后台时限 | 临时缩短模拟器 dataSync 时限后实际触发系统超时；服务停止，任务记录 `paused / service_timeout`；测试后恢复系统配置 |
| 最新候选逐页阅读 | 在 `1.9.0+82` 关闭 Wi-Fi、移动数据和样例服务器响应，从第 1 页依次读到第 12 页；所有页面无加载错误，服务器请求数为零，逐页截图留存 |
| 错误来源修复保护 | EX 模式下可以直接阅读 EH 本地漫画；点击修复提示先切回原站点，12 页记录保持完成，未发起请求 |
| 修复后刷新 | EX 第 1 页修复期间显示未缓存，完成后原阅读器直接显示图片；仅请求 `/image/ex/1001/0` |
| 末页定位 | 第 120 页修复暂停后显示未缓存；再次从列表阅读保持 120/120，不回跳至 119，不发网络请求；验收后补回该页 |
| 通知打开与删除 | 点击真实系统通知，在阅读器上方打开下载列表；确认删除 EX 漫画后管理页保持打开，返回不会回到被删阅读器。EX 文件目录删除，其他 3 本 / 180 页及历史保留 |

原始本地证据位于被 Git 忽略的 `build/offline-*.json`、`build/offline-*.sqlite`、`build/offline-shots/`。其中 `offline-v80-activity-recreation.json` 保存三次运行实例标识，`offline-v80-lock-completion.json` 保存锁屏完成结果，`offline-v80-origin-isolation.json` 保存来源隔离与摘要核验结果。

`offline-v82-all-pages.json` 及 12 张对应截图记录最新候选逐页阅读；`offline-v82-source-guard.json`、`offline-v82-repair-refresh.json`、`offline-v82-last-page.json` 和 `offline-v82-delete.json` 分别记录来源保护、修复刷新、末页恢复和删除结果。模拟器已恢复网络，样例漫画中的临时缺页已补回。

## 最终候选与构建

候选为 **1.9.0+82**，构建提交 `edf2e7d5a50eee3ecb58dfd0a3884e34556bd034`。候选来源提交 `2b1955d8e08e0d3b624a48e710c2df99ece43855`；通过项目自动版本流程生成，未手改版本号。

| 检查 | 结果与可追溯记录 |
| --- | --- |
| 候选准备 | [Prepare candidate 38400090237](https://github.com/fy142857/OViewer/actions/runs/38400090237) 成功；自动版本提交已快进同步回本地 dev |
| Android 正式签名候选构建 | [38400137671](https://github.com/fy142857/OViewer/actions/runs/38400137671) 成功，尚未发布 |
| Android 模拟器验收构建 | [38400299890](https://github.com/fy142857/OViewer/actions/runs/38400299890) 成功；包含 736 项 Flutter 测试、52 项版本/发布脚本测试、静态分析基线检查及 Android 原生测试 |
| iOS 候选构建 | [38400147174](https://github.com/fy142857/OViewer/actions/runs/38400147174) 成功 |
| 本地来源保护回归 | 协调器 15 项通过；静态检查无新增错误或警告 |
| 模拟器包身份 | `com.oviewer.oviewer.offline_test`，versionName `1.9.0`、versionCode `82`，仅用于隔离测试 |

模拟器 APK 大小为 63,126,788 字节，SHA-256 为 `fd856483830bea7c2ca6316f8ec0b2fcad95e07499863d7a7bd99fb7ac0c0b7c`。原始文件与日志保存在 `build/offline-emulator-v82.apk` 和 `build/offline-v82-android-logs.zip`。该 Debug 包与正式签名安装包用途不同。

## 范围说明

Android 按用户要求在模拟器验收，不将这些结果表述为手机或厂商电池管理测试。iOS 使用构建检查与生命周期自动化测试；未进行 iOS 设备运行验收。此次为开发候选，正式发布需另行授权。

