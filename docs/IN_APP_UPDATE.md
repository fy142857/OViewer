# Android 应用内更新

设置 → 关于 → 检查更新只在点击时访问 GitHub 最新正式 Release。Android 弹窗展示版本、安装包大小，以及该版本的“新增”“修复”“变更”说明，三个章节标题加粗；不显示历史版本、构建来源或校验摘要。弹窗始终为已获取的 Release 提供“跳转发布页（下载更稳）”链接。下载进度提示仅保留“隐藏后下载继续。”。

点击“立即更新”后应用内下载 APK。进度弹窗可隐藏，离开设置页也不会取消任务；再次点击检查更新可查看进度。“取消下载”停止当前任务，重试从头下载。不提供后台服务、通知、断点续传或进程退出后的下载保证。

下载完成并通过校验后，在应用前台打开安装流程；后台完成则等待返回前台。Android 8 及以上首次需要安装授权时，会先解释用途，再由用户决定是否打开系统设置。授权后返回接续一次安装。拒绝授权或取消系统安装后保留文件，点击“立即安装”可重试，不反复弹窗。打开系统安装器不表示安装成功，覆盖安装仍须用户确认。

iOS 保留原有确认后打开 Release 的流程，不请求 APK 清单，不下载或安装 IPA。

## 发布与校验

- 复用同一正式 Release 的 `OViewer.apk` 和 `release-manifest.json`，无需服务器或新增发布文件。清单的版本、候选信息、Android 构建信息和文件大小必须一致。
- 更新客户端独立于站点客户端，不发送 Cookie；使用现有代理路由，但始终正常校验 TLS 证书。只允许 GitHub 及其下载 CDN 的 HTTPS 重定向。
- 流式保存至私有缓存 `updates/package.part`，检查大小及 SHA-256 后改名为 `package.apk`，更新描述通过临时文件原子保存。下载使用连接和数据停滞超时，不限制总下载为 15 秒；版本检查仍有 15 秒总预算。
- 安装前重新校验文件，并由原生层检查包名、版本、递增构建号和证书。证书必须同时匹配当前已安装应用与清单；固定签名策略不支持签名轮换。Debug 签名安装无法覆盖为正式签名安装，提示用户处理，不卸载应用。
- Android 9 及以上同时请求 `GET_SIGNING_CERTIFICATES` 与 `GET_SIGNATURES`，兼容部分华为 Android 10 系统必须带旧标志才收集 APK 证书的行为；校验仍读取 `SigningInfo.apkContentsSigners`，不跳过或放宽证书一致性检查。
- FileProvider 只暴露私有缓存 `updates/`，安装桥接只接受其中的固定 APK 文件，授予安装器临时只读权限。
- 清单缺失、无效或构建号不高于当前安装时，保留新版提示并提供发布页入口，不绕过校验安装。

## 恢复与维护

下载、检查和安装状态由应用级 UpdateCubit 管理；取消使用代次隔离迟到结果，文件操作串行执行，避免旧任务删除重试的文件。

首帧之后执行本地轻量维护，删除进程中断留下的部分文件及已升级的旧安装包，并核对已保存的新版提示，不检查网络更新或自动安装。下次打开更新入口会重新校验完整包并显示“立即安装”；安装包被系统清理则重新下载。完整包不纳入漫画图片缓存的容量限制。安装器读取期间不会主动删除该文件。

首次获得此功能仍需使用旧版本的 Release 跳转流程安装；之后才能使用应用内更新。正式发布仍沿用项目的单独授权流程。

## 验证入口

- `flutter test --no-pub`：更新信息、下载完整性、恢复/取消、前后台及中英文组件回归。
- `python -m scripts.versioning.analyze`：现有静态分析基线；Windows 可传 `--dart C:\flutter\bin\cache\dart-sdk\bin\dart.exe`。
- `android/gradlew :app:testDebugUnitTest`：原生包信息、证书、路径和安装授权测试，API 21、26、28、29、35；测试依赖 Robolectric 4.14.1，应用最低系统要求保持不变。
- 真机验收需同一正式签名的递增构建，检查授权、覆盖安装，以及登录、历史、设置保留。自动化测试不替代真实系统安装器验收。

## 2026-10-09 验证记录

- 最终候选为 `1.8.0+69`，构建提交 `602fe49842b2f3451a519382b48a11caad86393b`。[Android 构建及原生测试](https://github.com/fy142857/OViewer/actions/runs/37915925474)与 [iOS 未签名 IPA 构建](https://github.com/fy142857/OViewer/actions/runs/37915932409)均成功；未创建正式 Release。
- 完整 Flutter 回归 684 项通过；现有 Python 发布回归 52 项通过；静态分析基线无新增错误或警告。原生测试覆盖 API 21、26、28、35，包括当前签名读取、包名/构建号/签名拒绝、受限 FileProvider、授权弹窗和设置不可用。
- 另用生产客户端通过本机代理访问真实公开 `v1.7.0` Release，正常 TLS 校验、GitHub CDN 重定向、29,721,215 字节 APK 下载、完整 SHA-256 校验及缓存恢复均通过。此验证未安装 APK，也未改变正式发布。
- 360×640 组件场景验证长说明滚动、发布页链接点击和更新按钮可见性；中英文下载隐藏、再次打开及安装触发由回归测试覆盖。
- Windows 本地 Gradle 启动仍受 Java 回环连接故障影响，原生测试及打包以以上 Linux CI 结果为准。
- 已连接 Android 10 真机上的 `1.7.0+66` 使用开发签名，与正式包签名不一致。仅备份并核对原 APK，没有卸载、覆盖安装、清除或修改应用数据。因此本次未验证正式签名包的真机覆盖升级及升级后的登录、历史、设置保留；需在同一正式签名的测试安装上补充验收。iOS 未进行真机安装验证。

## 2026-10-11 正式发布

按用户授权发布 [v1.8.0（69）](https://github.com/fy142857/OViewer/releases/tag/v1.8.0)。[发布预检](https://github.com/fy142857/OViewer/actions/runs/38116426241)和[正式发布](https://github.com/fy142857/OViewer/actions/runs/38116507937)均成功。标签固定在已验证构建提交 `602fe49842b2f3451a519382b48a11caad86393b`；直接复用上述 Android/iOS 构建，未重新编译或签名。

- 公开附件包含 `OViewer.apk`、`OViewer.ipa`、`release-manifest.json` 和 `SHA256SUMS.txt`，已核对大小及 SHA-256 与原候选一致；Android 继续使用固定正式证书，iOS IPA 未签名。
- APK SHA-256：`0397d2c915466a4efae0862ca491c0fc935a7fb1430200c09180b6861fb5bf67`。
- IPA SHA-256：`d47700502945a72a3ef4c78daf839488975fb6f0cd915f6224485bb35c4147a8`。
- 此次发布不包含手机卸载或安装操作，以上真机验收限制仍然适用。

## 2026-10-11 v1.8.1 发布

按用户授权发布 [v1.8.1（71）](https://github.com/fy142857/OViewer/releases/tag/v1.8.1)，包含更新弹窗展示及通知提示调整，以及自动代理探测端口补全。[Android 构建](https://github.com/fy142857/OViewer/actions/runs/38118021235)、[iOS 构建](https://github.com/fy142857/OViewer/actions/runs/38118025103)、[发布预检](https://github.com/fy142857/OViewer/actions/runs/38120737631)与[正式发布](https://github.com/fy142857/OViewer/actions/runs/38120806294)均成功。

标签固定在已验证候选提交 `b03132390e45492415fcad390b19096bb6409812`，复用原始构建产物。公开的四个附件已核对大小及 SHA-256；Android 使用原固定正式证书，iOS IPA 未签名。本次不包含手机卸载或安装操作。

- APK SHA-256：`ba76fe802f7d1b2ea9e01e9ab265c0f351aa28fc3f43ce12318cc1d7b2ada5b0`。
- IPA SHA-256：`2ce8e225b95a1f3a425bf01529b4dbf83f00f5f8a65e3114f5c8e2c7be14a679`。

## 2026-10-11 v1.8.2 发布

按用户授权发布 [v1.8.2（75）](https://github.com/fy142857/OViewer/releases/tag/v1.8.2)，包含卡片视图语言标识及图标、图片缓存说明调整。[Android 构建](https://github.com/fy142857/OViewer/actions/runs/38123266912)、[iOS 构建](https://github.com/fy142857/OViewer/actions/runs/38123271315)、[发布预检](https://github.com/fy142857/OViewer/actions/runs/38123897817)与[正式发布](https://github.com/fy142857/OViewer/actions/runs/38123991090)均成功。

标签固定在已验证候选提交 `2b5d9ed1135f19adfc2cab7e96b980781f01ed46`，复用原始构建产物。公开的四个附件已核对大小及 SHA-256；Android 使用原固定正式证书，iOS IPA 未签名。本次不包含手机卸载或安装操作。

- APK SHA-256：`310f99999421fccb0dca454ecd8330cd4ccd45974fe7c213fbdd9ed0582b9126`。
- IPA SHA-256：`252f03804a7d97a7129223b9e2b987109dcfe8ac3e857be3f3c9a8e35dd42832`。

## 2026-10-11 华为 Android 10 签名误报排查

VOG-AL10 真机当前安装的 `1.8.1+71` APK 与原正式附件 SHA-256 完全一致。该包与正式 `1.8.2+75` 更新包经 `apksigner` 验证，证书均为 `a30360a24fda76486fc152cb9e2e8cc5e7578c42c46d6aa430f3ae35adfa34e4`。

只读探针在此机复现：`getPackageArchiveInfo` 单独传 `GET_SIGNING_CERTIFICATES` 返回空的 `signingInfo` 和 `signatures`；同时传入 `GET_SIGNATURES` 后，`SigningInfo.apkContentsSigners` 返回与已安装应用一致的正式证书。修复为同时请求两个标志，保留当前签名与清单的严格比对。探针与手机临时 APK 已删除，未安装、卸载或清除应用数据；本次验证的是签名读取兼容性，未执行系统覆盖安装。

## 2026-10-11 v1.8.3 发布

按用户授权发布 [v1.8.3（77）](https://github.com/fy142857/OViewer/releases/tag/v1.8.3)，包含上述华为 Android 10 签名误报修复，以及更新窗口显示“修复”章节。[Android 构建与原生测试](https://github.com/fy142857/OViewer/actions/runs/38124665988)、[iOS 构建](https://github.com/fy142857/OViewer/actions/runs/38124669021)、[发布预检](https://github.com/fy142857/OViewer/actions/runs/38125473232)与[正式发布](https://github.com/fy142857/OViewer/actions/runs/38125559988)均成功。

标签固定在已验证候选提交 `404fddbbc679af73f2125ef6a32cb56f5fbde88c`，复用原始构建产物。公开的四个附件已核对大小及 SHA-256；Android 使用原固定正式证书，iOS IPA 未签名。受旧版签名误报影响的设备需先从发布页下载修复包，手动覆盖安装一次，无需卸载应用。本次发布未执行手机安装操作。

- APK SHA-256：`51d4cc4f7ff34a29b97d4009cf6ef05103e8265287b8a1f4aab5d8e1ddedadf1`。
- IPA SHA-256：`4a0016cd92cb39ae0db77010c1326d05c87d564c4b06db9923f9d3358c946771`。
