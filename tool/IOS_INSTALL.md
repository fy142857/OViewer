# iOS 命令行构建、下载和安装

在项目根目录运行 `tool/ios-install.cmd` 打开中文菜单。Python 3.10+、Git 用于构建和下载；自动安装支持 Windows 10/11，适配 Sideloadly 0.60 的英文界面。

## 首次准备

```powershell
python -m venv tool/.venv
tool/.venv/Scripts/python.exe -m pip install -r tool/requirements-ios.txt
.\tool\ios-install.cmd doctor
```

安装 [Sideloadly](https://sideloadly.io/) 及其要求的 Apple iTunes/iCloud 桌面组件，在 Sideloadly 中完成一次 Apple ID 登录。iPad 通过 USB 连接、解锁并信任电脑。需要时在 iPad 上开启开发者模式。首次认证、验证码及信任提示需本人处理；脚本不读取或保存 Apple 凭据。

GitHub 认证依次使用 `GH_TOKEN`、`GITHUB_TOKEN`、`gh auth token`、当前仓库的 Git Credential Manager 凭据。未登录时可用 `gh auth login`。细粒度 token 至少需 Actions:read（下载）；触发构建需 Actions:write，Git 推送需 Contents:write；修改 workflow 还需相应 workflow 权限。不要把 token 写进脚本或提交仓库。

Sideloadly 路径从注册表、PATH、常用安装目录及 `D:\Sideloadly` 查找；也可传 `--sideloadly "D:\Sideloadly\sideloadly.exe"` 或设置 `SIDELOADLY_PATH`。

## 自动模式

```powershell
# 先正常提交项目修改（脚本不会擅自提交工作区文件）
git add <要提交的文件>
git commit -m "your change"
.\tool\ios-install.cmd auto

# 仅构建和下载（自动模式仍要求先连接 USB iPad）
.\tool\ios-install.cmd auto --no-install
```

`auto` 的第一步是检测 USB iPad，菜单中的自动模式和 `auto --no-install` 也执行此检查。没有设备时立即以退出码 `2` 结束，不读取 GitHub 凭据、不推送、不触发构建、不下载、不启动 Sideloadly。多台设备需通过 `--udid` 指定目标；检测失败或指定设备不存在时同样停止。确认设备后要求干净的工作区，推送当前分支到 `origin`，跟踪同一提交 SHA 的新 iOS push 构建。当前提交已经推送、仅文档变更或其他分支未触发时，使用带唯一请求 ID 的 `workflow_dispatch`。分支必须包含本项目新增的 workflow 输入配置；不会误用其他提交或历史构建。默认等待构建 3600 秒，可用 `--timeout` 修改。

自动和手动下载均保存至项目 `ipa/`，文件名显示 GitHub Actions 构建序号，例如 `OViewer-Build iOS IPA #14.ipa`。同一构建重跑时加上 ` (attempt 2)`，同一构建有多个可选产物时加上 artifact ID，避免不同版本互相覆盖。每个 IPA 附带 JSON 文件，记录构建序号、run ID、重跑次数、提交 SHA、artifact ID、来源和 SHA-256。下载使用临时文件、SHA-256（GitHub 提供时）与 IPA CRC 校验，成功后原子替换。兼容当前 `archive: false` 直接上传 IPA 和历史 ZIP 包装格式。下载目录与 IPA 已加入 Git 忽略规则。

下载后再次检测 USB iPad，按启动时确定的 UDID 匹配 Sideloadly 中的目标设备，载入 IPA 并触发 Start，等待本次安装的 `Done.` 状态。若设备在构建期间断开，保留下载并停止安装，不会改选其他设备。保留现有 Apple ID 与高级签名配置，更新原应用时应继续使用原来的 Apple ID／Bundle ID。

只有本次 iOS 构建状态为 `completed / success` 且产物下载、校验成功，才会继续安装。轮询检测到 iOS job／步骤失败、取消或超时时，立即以退出码 `1` 终止本地脚本，不再下载，不启动 Sideloadly，也不回退安装历史 IPA；无需等待 GitHub runner 清理结束。构建成功但 IPA 缺失、过期或校验失败同样退出。这里终止的是本地自动化进程，GitHub runner 的清理任务仍由 GitHub 完成。

## 手动版本和本地安装

```powershell
.\tool\ios-install.cmd manual                 # 最近 10 次构建 → 选择下载 → 选择本地 IPA 安装
.\tool\ios-install.cmd list                   # 只列最近 10 次 iOS 构建
.\tool\ios-install.cmd download               # 下载最近成功的构建，不自动安装
.\tool\ios-install.cmd download --run-id 123   # 下载指定 iOS 构建
.\tool\ios-install.cmd install                # 选择本地 IPA 后安装
.\tool\ios-install.cmd install --ipa "D:\path\OViewer.ipa"
.\tool\ios-install.cmd install --udid "your-device-udid"
```

`manual` 和 `download` 下载不要求连接 iPad；选择安装时再检测设备。`manual` 列出最近 10 次构建（包括失败、进行中的记录），显示时间、分支、提交和结果；只有成功且未过期的产物可下载。产物保留 30 天，过期时需重新构建。选择序号 `0` 返回／只保留下载。安装菜单扫描 `ipa/`、项目根目录及 `build/ios/` 中的 IPA；`--output` 可更改下载／扫描目录。

首次认证或签名错误请查看 Sideloadly 窗口。自动安装依赖其 UI 控件；界面不匹配时会停止并报错，不会使用屏幕固定坐标盲点。默认安装超时 900 秒，可通过 `--install-timeout` 调整。Ctrl+C 只停止脚本等待，不会取消已启动的 Actions 或 Sideloadly 任务。

退出码：`0` 操作完成或用户退出；`1` 失败／未确认成功；`2` 未连接 USB iPad（自动流程未启动，或安装时已保留下载）；`130` 用户中断。

## 验证

```powershell
python -m unittest discover -s tool -p "test_ios_install.py" -v
```

单元测试覆盖 IPA／历史 ZIP、校验失败、过期产物、下载重定向凭据隔离、构建提交匹配，以及无设备和多设备分支。完整安装还依赖实际 Windows 桌面、Apple 驱动、USB 设备和 Sideloadly 登录状态。
