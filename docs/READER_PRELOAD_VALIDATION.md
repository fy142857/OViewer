# 图片链接领先范围的真机验证

## 要回答的问题

图片仍按用户选择预加载前后各 N 页／组。以直链在两侧各领先 1 页／组为基准，比较范围相同、领先 2 和 3 页／组，判断扩大是否缩短实际翻页等待。单页的一组是一张图片，双页的一组是两张；边界按书籍总页数裁剪。

参数比较维持项目已有的链接请求调度、请求复用和可见页处理，只改变直链目标范围。图片预加载仍使用两个后台任务。

## 实测方法

- Huawei VOG-AL10 / Android 10，Flutter 3.13.9 / Dart 3.1.5，arm64 Profile 构建。
- 独立包名 `com.oviewer.oviewer.preload_bench`，使用真实生产 ReaderScreen、Bloc、图片下载、磁盘缓存及解码路径。没有使用用户漫画、登录凭据或公网图库。
- Windows / Python 3.12.0 的本机 HTTP fixture 经 USB ADB reverse 提供可控网络条件；这是真机应用侧实测，不是计算模型，也不是公网线路测速。请求字节数统计服务端写出的响应正文。
- 每页为 900×1500 的确定性 PNG，175500 字节。图片页面响应约 16 KiB。HTML 和图片共享每组的带宽额度。
- 三种网络：普通（HTML 250ms、图片响应前延迟 80ms、带宽上限 2048 KiB/s）；慢链接（1200ms、60ms、上限 2048 KiB/s）；受限带宽（350ms、80ms、上限 160 KiB/s）。实际吞吐还包括 Windows 定时调度、HTTP 处理及 USB 转发开销。这些是人工设定的条件，不代表用户实际网络分布。
- 每组开始前清空独立测试包的图片磁盘缓存及内存缓存，并核实缓存字节数为 0。不同组使用不同图库 ID/图片 URL。用户的正式版、Debug 版及其数据不参与清理。
- 初始目标页显示后固定等待 2 秒，再连续翻页。每次通过真实阅读器的滚动控制器执行 180ms 动画；下一次翻页间隔为 350ms 或 800ms，若图片尚未显示则等到该次测量完成。
- 完成条件为目标页／组的所有图片均有已解码 RawImage 与屏幕相交，且已结束对应渲染帧。记录开始翻页至显示的总时间，以及滚动结束后仍需等待的时间。不是以拿到链接、下载结束或资源就绪事件代替显示完成；也不是摄像机测得的屏幕光子延迟。
- 每次最多观察 10 秒；超时原样保留并报错，不删除超时样本以改善结果。P95 使用 nearest-rank 定义。

## 判定原则

优先比较相同网络、图片数量、页型、方向和节奏的分组结果，同时观察平均等待、中位数、P95、超过 100ms 的次数与额外请求量。P95 不变并不意味着等待频率没有改善。小于一帧的差异不直接归因于领先范围；扩大的实质收益参考平均每次等待降低至少 20ms 且 10%，或 P95 降低至少 50ms 且 10%，并经交叉复测。若扩大没有稳定收益、主要瓶颈已是图片下载，或增加请求后出现明显退化，保留较小范围。

## 测量质量控制

探索阶段试验过“额外范围只允许一个链接任务”，但这个新增调度限制可能让更大的范围无法及时被利用，不能单独用来回答原调度下应领先多少。最终参数判断使用 `existing_scheduler_*` 阶段：恢复原链接调度后只改变领先数量。单任务实验记录保留作诊断，不混入最终比较。

最初的试运行只使用不同 URL 隔离缓存命中，但没有清空磁盘缓存。排查发现缓存写入时的配额维护会扫描已有文件，随测试轮次累积的缓存使后测方案额外变慢。因此该批数据只作为诊断材料，不能用于领先范围的因果比较。正式比较增加每组空缓存校验。

手机休眠中断的未完成组不纳入结果；恢复原充电常亮设置、由用户解锁后重新开始该组。已完整保存的组与中断组分开记录。

纵向驱动最初只调用滚动控制器，未产生用户拖动开始事件，因而保留了阅读器的明确入口页定位。该批纵向超时是无效驱动产生的结果，原始数据保留但不用于参数比较。修正驱动先通过真实命中测试发送拖动事件，再从相同入口位置开始计时；记录实际页码和可见页验证推进。复测使用生产 ReaderRoute（包括 Android 立即返回），避免通用路由的退出动画继续布局已取消的阅读器。参数判断使用翻页后的显示等待，不将两版驱动的入口耗时直接相减。

## 复测工具

- `scripts/reader_preload_fixture.py`：只绑定 127.0.0.1 的 HTTP fixture，按每组独立配置限速并保存逐请求记录。
- `test_driver/reader_preload_benchmark.dart`：独立包名保护、空缓存校验、真实滚动和逐帧显示检测。
- `scripts/run_reader_preload_benchmark.py`：安装前校验包名，采集进度与日志，检查设备休眠／锁屏，保留不完整组以供排查。
- `scripts/analyze_reader_preload_benchmark.py`：逐组统计，并可用 `--plan` 校验整个比较矩阵完整。

方案 JSON 是一个数组，每组包括 `profile`、`html_ms`、`image_ms`、`kbps`、`n`、`mode`、`double`、`pace_ms`、`turns`、`repeat`、`warmup_ms` 和 `stage`。`mode` 为 0/1/2；`backward: true` 表示在同一阅读方向中回翻。

先启动 `python -m scripts.reader_preload_fixture --plan build/preload-bench-plan.json --output build/preload-clean-results.jsonl`，为选定设备添加 `adb -s <serial> reverse tcp:8765 tcp:8765`。启动前确认该端口及映射未被其他任务占用。

Profile 构建使用仅位于 `build/` 的初始化脚本，不能修改正式版包名：

```groovy
allprojects { p ->
    p.afterEvaluate {
        if (p.path == ':app') {
            p.android.buildTypes.profile.applicationIdSuffix = '.preload_bench'
            p.android.buildTypes.profile.manifestPlaceholders.appLabel = 'OViewer Preload Bench'
        }
    }
}
```

用目标 Flutter SDK 执行 `flutter pub get` 后，从项目根目录构建各对照包（PowerShell 示例）：

```powershell
$defines = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('READER_ADDRESS_LEAD=1'))
./android/gradlew.bat -p android :app:assembleProfile -I ../build/preload-bench.init.gradle `
  '-Ptarget=D:/AndroidStudioProjects/o_viewer/test_driver/reader_preload_benchmark.dart' `
  '-Ptarget-platform=android-arm64' "-Pdart-defines=$defines"
```

将输出复制成对应的对照 APK。`run_reader_preload_benchmark` 接受 `--adb`、`--aapt`、`--serial`、`--apk`、`--lead`、`--plan`、`--results`、`--log`；它会先用 aapt 核实包名，再安装并运行。比较时更改 `READER_ADDRESS_LEAD`，其他构建和测试条件一致。Windows Java 临时 socket 路径问题可按 `READER_ENTRY_VALIDATION.md` 中的方法为当前命令设置短临时路径。

汇总命令示例：`python -m scripts.analyze_reader_preload_benchmark docs/benchmarks/reader-preload/measurements.jsonl --stage existing_scheduler_screen --plan docs/benchmarks/reader-preload/screen-plan.json --leads 0,1,2,3 --output build/preload-existing-summary.json`。该命令拒绝缺失、重复、参数不匹配、起始缓存不为空、HTTP 记录未收齐、目标页未推进、请求越界或超时的比较，不能把部分样本报告为完整通过。超时原始记录仍保留。

测试结束后仅卸载本次创建的 `com.oviewer.oviewer.preload_bench`，删除本次新增的 8765 反向映射，停止本次 fixture/logcat 进程，并核对设备常亮设置与测试前一致。

## 结果与默认策略

有效对照共 **89 组、1392 次翻页，0 次超时**：首轮 48 组／768 次，跨预加载数量和阅读方向的复测 34 组／512 次，领先 3 的关键场景复测 3 组／48 次，高数量双页交叉复测 4 组／64 次。探索阶段和无效驱动数据不包含在这些数字中。

采用以下分档策略，图片预加载仍由原设置 N 决定：

| 图片前后各 N 页／组 | 链接前后各预读 | 每侧领先 |
|---:|---:|---:|
| 1 | 3 | 2 |
| 2 | 4 | 2 |
| 3 | 5 | 2 |
| 4 | 5 | 1 |
| 5 | 6 | 1 |

### 预加载 3 时，扩大到 2 有稳定收益，3 没有进一步的实质收益

下表是慢链接、350ms 翻页间隔、预加载 N=3 的两轮对照。每个单元为 **平均额外等待 / P95，毫秒**；每个布局、每个领先值各 32 次翻页。额外等待从滚动动画结束计到目标图片渲染完成，不含约 180ms 动画本身。

| 页型 | 每侧领先 1 | 每侧领先 2 | 每侧领先 3 |
|---|---:|---:|---:|
| 单页 | 64.13 / 165.07 | 3.18 / 5.37 | 3.87 / 6.02 |
| 双页 | 135.49 / 246.44 | 27.05 / 149.58 | 21.61 / 165.25 |

双页从领先 2 到 3 的平均收益约 5ms，低于一帧，P95 没有改善。每个 16 次连续翻页的测试段，领先 2 相比领先 1 累计增加 2 次链接页面请求（单页）或 4 次（双页）；再到 3 又增加相同数量。因此选 2，而不是继续扩大。

### 图片数量较小时有帮助，较大时保持 1

慢链接、快速翻页的补充对照中，N=1 单页从领先 1 到 2 的平均等待为 329.21→192.34ms，双页为 376.45→229.64ms；N=2 单页为 195.12→35.75ms，双页为 225.91→148.02ms。

N=4 的单页均约 3ms；双页平均 21.47→11.26ms，差异约 10ms，P95 差异约 33ms，未达到本次实质收益门槛。N=5 没有明显收益，双页三轮交叉复测（每值 48 次）反而出现更多尾部等待：

| N=5 双页 | 平均额外等待 ms | P95 ms | 超过 100ms | 链接请求数 |
|---|---:|---:|---:|---:|
| 每侧领先 1 | 12.23 | 83.78 | 2 / 48 | 174 |
| 每侧领先 2 | 25.54 | 148.48 | 5 / 48 | 186 |

因此 N=4–5 保持领先 1，避免没有稳定收益的额外请求。这是按已有图片数量选择的静态默认规则，不增加新的用户设置，也不根据一次网络波动反复改值。

### 方向与条件边界

N=3 慢链接快翻下，右到左单页平均等待 72.40→4.03ms、双页 125.82→32.22ms；回翻单页 54.69→3.47ms、双页 92.30→7.41ms。纵向两个领先值均约 2–3ms，目标页通常已在可见或预加载区域，没有明显差异。

普通网络和较慢翻页时，较小范围通常已经足够。带宽受限时主要等待仍来自图片下载，扩大链接范围不能解除该瓶颈。测试使用合成 PNG 和受控本机服务器，未覆盖公网限流、登录状态、真实漫画编码复杂度或所有网速；结论是本次覆盖条件下的默认折中，并非任意网络的数学最优值。大量已有磁盘缓存的独立维护开销也不能由本次链接范围调整消除。

## 证据与验收

- [逐组原始请求与帧记录](benchmarks/reader-preload/measurements.jsonl)：包含所有有效组的参数、HTTP 起止与响应字节数、逐次动画／显示等待、实际页码和可见页。
- [数据及 APK 摘要](benchmarks/reader-preload/metadata.json)：样本数、SHA-256、测试设备与最终策略。
- [首轮计划](benchmarks/reader-preload/screen-plan.json)、[复测计划](benchmarks/reader-preload/confirm-plan.json)、[领先 3 复测](benchmarks/reader-preload/extra-plan.json)、[高数量交叉复测](benchmarks/reader-preload/guard-plan.json)。各计划都有同目录下的 `*-summary.json`。
- [最终默认策略验证](benchmarks/reader-preload/policy-check.jsonl)：5 组／25 次翻页，没有 `READER_ADDRESS_LEAD` 参数覆盖；N=1–3 实际选择领先 2，N=4–5 实际选择领先 1，均成功显示。

独立测试包已卸载，8765 反向映射和 fixture 服务已清理。设备常亮设置前后均为 7；正式版和 Debug 包保留。

Flutter 3.16.0 完整回归 **1122 项通过**，Python 脚本回归 **56 项通过**；静态分析保持 157 条既有诊断，无新增错误或警告，真机驱动单独分析无问题。最终分档默认策略另外通过 Flutter 3.13.9 Profile 构建及上述无参数覆盖的真机验证。本地依赖解析恢复到用户当前使用的 Flutter 3.13.9。

提交前进一步加强了原组件用例，直接核对实际 HTML 请求覆盖完整链接窗口，相关 **58 个场景全部通过**。
