"""Windows USB detection and semantic UI Automation for Sideloadly v0.60.

No Apple passwords, OTPs or signing credentials are read or entered by this module.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


def connected_ipads():
    if os.name != "nt":
        raise RuntimeError("Sideloadly 自动安装目前仅支持 Windows；IPA 下载可跨平台使用。")
    # WPD identifies the product even when the device's user-given name is different.
    # Walk USB parents to obtain the UDID used by Sideloadly, rather than the WPD interface ID.
    script = r"""
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$ipads = @(Get-PnpDevice -PresentOnly | Where-Object {
    $_.FriendlyName -match 'iPad' -and $_.InstanceId -match 'VID_05AC' -and $_.Status -eq 'OK'
})
$result = @(foreach ($ipad in $ipads) {
    $instance = $ipad.InstanceId
    $udid = $null
    for ($depth = 0; $depth -lt 6; $depth++) {
        if ($instance -match '^USB\\VID_05AC[^\\]*\\([0-9A-Fa-f-]{20,})$') {
            $udid = $Matches[1].ToLowerInvariant()
            break
        }
        $parent = Get-PnpDeviceProperty -InstanceId $instance -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue
        if (-not $parent.Data) { break }
        $instance = $parent.Data
    }
    [pscustomobject]@{ name = $ipad.FriendlyName; udid = $udid }
})
ConvertTo-Json -InputObject $result -Compress
"""
    result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
                            capture_output=True, encoding="utf-8", errors="replace", timeout=45,
                            creationflags=subprocess.CREATE_NO_WINDOW)
    if result.returncode:
        raise RuntimeError("无法查询 USB 设备，请检查 Windows PnP 服务及运行权限。")
    return json.loads(result.stdout.strip() or "[]")


def find_sideloadly(explicit=None):
    configured = explicit or os.getenv("SIDELOADLY_PATH")
    if configured:
        candidate = Path(configured).expanduser().resolve()
        if not candidate.is_file() or candidate.suffix.lower() != ".exe":
            raise RuntimeError("指定的 Sideloadly.exe 不存在。")
        return candidate
    candidates = []
    if shutil.which("sideloadly.exe"):
        candidates.append(Path(shutil.which("sideloadly.exe")))
    if os.name == "nt":
        import winreg
        for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
            for key in (r"Software\Classes\sideloadly\shell\open\command",
                        r"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\sideloadly.exe"):
                try:
                    with winreg.OpenKey(hive, key) as handle:
                        value = winreg.QueryValue(handle, None)
                    match = re.match(r'"([^"]+\.exe)"|(.+?\.exe)(?:\s|$)', value, re.I)
                    if match:
                        candidates.append(Path(match[1] or match[2]))
                except OSError:
                    pass
    for env in ("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"):
        if os.getenv(env):
            candidates.append(Path(os.environ[env]) / "Sideloadly" / "sideloadly.exe")
    candidates.append(Path(r"D:\Sideloadly\sideloadly.exe"))
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise RuntimeError("找不到 Sideloadly。请安装后使用 --sideloadly 指定 exe，或设置 SIDELOADLY_PATH。")


def doctor(explicit=None):
    print(f"Sideloadly：{find_sideloadly(explicit)}")
    devices = connected_ipads()
    print(f"USB iPad：{len(devices)} 台")
    for device in devices:
        print(f"  {device['name']} (UDID 尾号 {(device['udid'] or '未知')[-6:]})")
    try:
        import pywinauto  # noqa: F401
        print("Windows UI Automation 依赖正常。")
    except ImportError:
        raise RuntimeError("请先运行 python -m pip install -r tool/requirements-ios.txt") from None


def normalized_udid(value):
    return re.sub(r"[^0-9a-f]", "", value.lower())


def select_device(devices, requested=None):
    if not devices:
        return None
    if requested:
        matched = [d for d in devices if d.get("udid") and normalized_udid(d["udid"]) == normalized_udid(requested)]
        if len(matched) != 1:
            raise RuntimeError("指定的 iPad 未通过 USB 连接。")
        return matched[0]
    if len(devices) != 1:
        raise RuntimeError("检测到多台 iPad，请用 --udid 指定目标（可在 Sideloadly 中查看）。")
    if not devices[0].get("udid"):
        raise RuntimeError("已发现 iPad，但无法读取 USB UDID；请检查 Apple 驱动和设备信任状态。")
    return devices[0]


def device_item(items, udid):
    matches = [item for item in items if "@USB" in item.upper() and
               normalized_udid(udid) in normalized_udid(item)]
    if len(matches) != 1:
        raise RuntimeError("Sideloadly 中未找到唯一匹配的 USB iPad，请解锁设备并信任此电脑。")
    return matches[0]


def unique(controls, label):
    if len(controls) != 1:
        raise RuntimeError(f"无法唯一识别 Sideloadly 的{label}；请检查弹窗或版本变化。")
    return controls[0]


def button(window, title):
    return unique([c for c in window.descendants(control_type="Button") if c.window_text() == title], title)


def combo(window, title):
    return unique([c for c in window.descendants(control_type="ComboBox") if c.window_text() == title], title)


def texts(window):
    return [c.window_text().strip() for c in window.descendants(control_type="Text")]


def ipa_dialogs(app, window):
    # Qt exposes the native owned dialog under its main UIA window on Windows 11.
    # Application.windows() alone only sees top-level windows and can miss it.
    candidates = app.windows() + window.descendants(title="Choose IPA File")
    return list({w.handle: w for w in candidates
                 if w.window_text() == "Choose IPA File" and w.is_visible()}.values())


def matches_ipa_label(label, filename):
    # Sideloadly inserts zero-width word breaks and Qt elides long run-specific names.
    label = label.replace("\u200b", "")
    if label == filename:
        return True
    parts = label.split("…")
    return (len(parts) == 2 and len(parts[0]) >= 16 and
            filename.startswith(parts[0]) and filename.endswith(parts[1]))


def load_ipa(app, window, path):
    # The IPA picker is the large icon button to the left of iDevice. It has no accessible name.
    # Use its relationship to the labeled device combo, never absolute desktop coordinates.
    if not ipa_dialogs(app, window):
        device_rect = combo(window, "iDevice:").rectangle()
        candidates = [c for c in window.descendants(control_type="Button")
                      if c.is_visible() and c.rectangle().width() >= 55 and c.rectangle().height() >= 60
                      and c.rectangle().right <= device_rect.left]
        # Some Qt versions expose the same icon as both a parent and a child button.
        by_rect = {(c.rectangle().left, c.rectangle().top, c.rectangle().right, c.rectangle().bottom): c for c in candidates}
        picker = unique(list(by_rect.values()), "IPA 文件选择按钮")
        picker.invoke()
    deadline = time.monotonic() + 15
    dialog = None
    while time.monotonic() < deadline:
        dialogs = ipa_dialogs(app, window)
        if len(dialogs) == 1:
            dialog = dialogs[0]
            break
        time.sleep(0.3)
    if dialog is None:
        raise RuntimeError("未打开 IPA 文件对话框。")
    edits = [c for c in dialog.descendants(control_type="Edit")
             if c.element_info.automation_id in ("1148", "1001")]
    filename_edit = unique(edits, "文件名输入框")
    filename_edit.set_edit_text(str(path))
    if filename_edit.get_value() != str(path):
        raise RuntimeError("文件对话框未接受所选 IPA 的完整路径。")
    opens = [c for c in dialog.descendants(control_type="Button")
             if c.element_info.automation_id == "1"]
    unique(opens, "打开文件按钮").invoke()
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if not ipa_dialogs(app, window) and any(matches_ipa_label(t, path.name) for t in texts(window)):
            return
        time.sleep(0.5)
    raise RuntimeError("Sideloadly 未确认载入所选 IPA。")


def install_ipa(path, explicit=None, udid=None, timeout=900):
    device = select_device(connected_ipads(), udid)
    if device is None:
        print(f"未检测到 USB iPad，已保留 IPA：{path}\n连接后在项目根目录运行 tool/ios-install.cmd install。")
        return 2
    executable = find_sideloadly(explicit)
    try:
        from pywinauto import Application
        from pywinauto.application import ProcessNotFoundError
    except ImportError:
        raise RuntimeError("请先运行 python -m pip install -r tool/requirements-ios.txt") from None
    print("已检测到 USB iPad，正在启动／连接 Sideloadly…", flush=True)
    app = Application(backend="uia")
    try:
        app.connect(path=str(executable), timeout=3)
    except ProcessNotFoundError:
        # Interactive app: keep its window visible for Apple authentication prompts.
        subprocess.Popen([str(executable)], cwd=executable.parent)
        app.connect(path=str(executable), timeout=30)
    window = app.window(title_re=r"^Sideloadly!.*").wait("exists", timeout=30)
    if window.is_minimized():
        window.restore()
    window.set_focus()
    if any(c.window_text() in ("Cancel", "Stop") for c in window.descendants(control_type="Button")):
        raise RuntimeError("Sideloadly 已有安装任务，请等待完成后重试。")
    load_ipa(app, window, path)
    devices = combo(window, "iDevice:")
    target = device_item(devices.texts(), device["udid"])
    if devices.selected_text() != target:
        devices.select(target)
    selected = devices.selected_text()
    if device_item([selected], device["udid"]) != target:
        raise RuntimeError("Sideloadly 目标设备选择未生效。")
    print("已载入所选 IPA。若出现 Apple ID、密码、验证码或信任提示，请在 Sideloadly／iPad 上完成。", flush=True)
    deadline = time.monotonic() + timeout
    while not button(window, "Start").is_enabled():
        if time.monotonic() >= deadline:
            raise RuntimeError("等待 Sideloadly 就绪超时；请完成 Apple ID 配置后重试。")
        time.sleep(1)
    # Re-check USB identity immediately before the installation action.
    select_device(connected_ipads(), device["udid"])
    device_item([combo(window, "iDevice:").selected_text()], device["udid"])
    previous = texts(window)
    button(window, "Start").invoke()
    started, report_at = False, 0
    while time.monotonic() < deadline:
        current = texts(window)
        starts = [c for c in window.descendants(control_type="Button") if c.window_text() == "Start"]
        busy = len(starts) != 1 or not starts[0].is_enabled()
        started = started or current != previous or busy
        if started and any(re.match(r"^(ERROR:|Failed|Installation failed|Guru Meditation)", t, re.I) for t in current):
            raise RuntimeError("Sideloadly 报告安装失败，请查看其窗口中的错误信息。")
        if started and not busy and "Done." in current:
            print(f"Sideloadly 报告安装完成：{path.name}", flush=True)
            return 0
        if time.monotonic() - report_at >= 30:
            print("正在等待 Sideloadly 安装结果；认证提示需手动完成…", flush=True)
            report_at = time.monotonic()
        time.sleep(0.5)
    raise RuntimeError("等待安装结果超时；未确认安装成功，请查看 Sideloadly。后台安装不会被强制终止。")
