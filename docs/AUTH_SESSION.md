# 登录会话与退出清理

## Issue #51 的原因

原实现退出时仅调用持久 CookieJar 的 `deleteAll()`。Android WebView 和 iOS 默认 WKWebsiteDataStore 仍保留登录 Cookie；退出后的登录页立即创建浏览器，读出旧凭据并提交 `LoginFromWebView`，导致账号自动回来。原有认证事件和 Dio Cookie 拦截器也未阻止退出前任务回写状态或 `Set-Cookie`。

## 退出协议

1. AuthBloc 收到退出事件后立即进入 `loggingOut`，清除界面中的账号身份并使旧登录事件失效。签到模块随认证状态变化取消旧账号任务。
2. CookieManager 增加会话代次并暂停认证读写，将 `logout-pending` 标记写入应用私有 Cookie 目录；清理任务合并，并与 Cookie 写入、浏览器同步共享串行队列。
3. 定向移除 `ipb_member_id`、`ipb_pass_hash`、`ipb_session_id`、`igneous`、`sk`。范围为 EH、EX 及其论坛/子域；应用 CookieJar 和原生浏览器都处理。保留 `uconfig`、Cloudflare 验证 Cookie、其他非登录 Cookie，以及本地历史、收藏、下载等数据。
4. 原生清理后重新读取确认认证 Cookie 消失，随后移除待清理标记、进入游客状态。清理失败进入 `logoutFailed`，保留标记并提供“重试”入口。
5. 登录页在初始检查、退出中或清理失败期间不创建 WebView；清理完成后才打开新的登录会话。应用重启发现待清理标记时，先继续清理再返回登录状态。

退出只清理 OViewer 应用内的会话，不调用网站的全设备注销功能，也不影响系统浏览器中的登录。

## 防止旧会话恢复

- AuthBloc 为异步认证操作记录代次，旧状态检查、登录验证和用户资料结果不得覆盖退出或新账号。
- WebView 登录事件携带界面会话代次；浏览器内部异步 Cookie 读取也有失效标记，禁用后再启用不接收前一次读取结果。
- Dio 在等待代理前固定请求的会话代次，Cookie 拦截器在发送前及读取 Cookie 后重新检查，旧请求不能使用新账号的 Cookie，在保存正常或错误响应的 Cookie 前重新校验。旧响应直接跳过保存；游客请求也不能通过响应中的认证 Cookie 自动建立新登录。
- 浏览器 Cookie 同步和退出共用串行队列，并在异步边界校验代次；退出会清除已经写入的旧同步结果。站点设置页面在等待代理及同步完成后再次检查会话，防止旧页面准备任务创建浏览器。
- 本地登录检查必须同时存在非空会员 ID 和登录凭据，单个残留 Cookie 不算登录。

## 存储实现约束

项目锁定的 cookie_jar 4.x 没有按名称删除接口，且设置了 `ignoreExpires: true`，不能仅写过期认证 Cookie。清理通过公开的 Cookie 映射和 Storage 接口筛除认证条目，保留 `SerializableCookie` 的原始元数据，再写回对应域和主机文件；覆盖从磁盘重新读取的 host-only Cookie。

iOS 枚举默认 WKWebsiteDataStore 的 Cookie，并按实际 domain/path 删除；该存储与原生登录视图共享。Android API 不返回域和路径，清理覆盖 EH、EX、论坛的 host-only 与共享域变体，以及登录/设置相关路径，并回读检查。插件维持 5.8.0，不增加低版本 iOS 不支持的依赖。

Cookie 值和认证页面不会写入调试日志。诊断只包含清理错误类型与代码位置。

## 验证

- 相关认证、Cookie、WebView、签到测试共 82 项通过；全量 Flutter 测试 462 项通过，统一静态分析无新增错误或警告。
- 新增测试覆盖磁盘中不同域/路径的认证删除与偏好保留、原生双端选择性删除、失败后进程恢复、重复退出合并、旧成功/错误响应回写、匿名响应凭据过滤、旧登录验证和 WebView 回调失效、退出状态阻止浏览器创建。
- Android Huawei VOG-AL10 真机对照：旧版确认退出后自动出现“登录成功”，认证 Cookie 重新写回；修复版退出后保持登录页，认证 Cookie 为空，非登录 Cookie 与测试前完全一致。重启并再次打开登录页后仍为游客。测试凭据只在进程内存中备份，完成后恢复原 APK 和应用 Cookie 文件。
- iOS 完成组件层验证；暂无可用真机，原生运行留待设备可用时补充。双平台安装包构建由 dev 候选工作流验证。
