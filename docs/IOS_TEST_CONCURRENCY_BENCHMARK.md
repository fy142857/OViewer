# iOS Flutter 测试并发对照（2026-11-01）

## 结论

九次运行全部通过同一套 1,083 项测试，无失败、崩溃、超时或自动重试。并发 2、3 在每轮都快于串行基线；按三轮中位数分别缩短 **28.0%** 和 **32.0%**。

并发 3 的中位数比并发 2 快 **5.5%（8.3 秒）**，低于事先约定的 10% 门槛。前两轮并发 2 更快，第三轮并发 3 更快，且两档范围重叠；三个样本不足以确认 2 与 3 的稳定速度优劣。若后续需要选默认值，按预设规则保守优先 **2**，不是认定 2 更快或更稳定。

**实验阶段仅报告结果，没有修改日常 CI、发布新版本或更改 main。**

后续采用（2026-11-01）：维护者明确选择 **3 并发**，日常 iOS 工作流的两条 Flutter 测试命令均固定为 `--concurrency=3`。慢测试选择规则保持不变；以下仍保留原始实验结果和预设推荐判断，不将维护者的选择改写为实验结论。

## 原始耗时与运行链接

单位为秒；计时包含 Flutter 测试命令自身启动、测试编译、执行和退出，不包含 runner 排队、SDK/依赖准备、代码生成、静态检查或 artifact 上传。

| 并发 | 第 1 轮 | 第 2 轮 | 第 3 轮 | 中位数 | 最小–最大 | 相对串行中位数缩短 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 273.2 | 209.4 | 209.5 | 209.5 | 209.4–273.2 | 0.0% |
| 2 | 150.8 | 101.5 | 188.2 | 150.8 | 101.5–188.2 | 28.0% |
| 3 | 156.0 | 118.8 | 142.5 | 142.5 | 118.8–156.0 | 32.0% |

| 轮次 | 并发 | 耗时 | 通过 / 实际执行 | Actions 链接 |
| --- | ---: | ---: | ---: | --- |
| 1 | 1 | 273.2 | 1,083 / 1,083 | [任务 124690803766](https://github.com/fy142857/OViewer/actions/runs/41253196906/job/124690803766) |
| 1 | 2 | 150.8 | 1,083 / 1,083 | [任务 124690803859](https://github.com/fy142857/OViewer/actions/runs/41253196906/job/124690803859) |
| 1 | 3 | 156.0 | 1,083 / 1,083 | [任务 124690803907](https://github.com/fy142857/OViewer/actions/runs/41253196906/job/124690803907) |
| 2 | 1 | 209.4 | 1,083 / 1,083 | [任务 124692868139](https://github.com/fy142857/OViewer/actions/runs/41253892558/job/124692868139) |
| 2 | 2 | 101.5 | 1,083 / 1,083 | [任务 124692867875](https://github.com/fy142857/OViewer/actions/runs/41253892558/job/124692867875) |
| 2 | 3 | 118.8 | 1,083 / 1,083 | [任务 124692868194](https://github.com/fy142857/OViewer/actions/runs/41253892558/job/124692868194) |
| 3 | 1 | 209.5 | 1,083 / 1,083 | [任务 124694380719](https://github.com/fy142857/OViewer/actions/runs/41254397665/job/124694380719) |
| 3 | 2 | 188.2 | 1,083 / 1,083 | [任务 124694380547](https://github.com/fy142857/OViewer/actions/runs/41254397665/job/124694380547) |
| 3 | 3 | 142.5 | 1,083 / 1,083 | [任务 124694380747](https://github.com/fy142857/OViewer/actions/runs/41254397665/job/124694380747) |

## 对照条件与完整性

- 固定已发布候选 `1.11.1+139`，源码 SHA `dbf940b36996169f0817a3b45480d0f50cc3ec6e`；所有样本实际 checkout SHA 相同。
- 全部使用 `macos-15` ARM64，镜像 `20261028.0489.1`、macOS 15.8.2、3 核 Apple M1 (Virtual)、7 GiB 内存、Xcode 16.4、Flutter 3.16.0 / Dart 3.2.0；版本和硬件报告一致。
- 每轮三档各用独立的新 GitHub-hosted runner，轮间串行；代码生成等前置步骤一致。只缓存 SDK/Pub，不复用 `build/test_cache` 等测试编译产物。
- 第一轮三档均未命中 SDK/Pub 缓存，第二、三轮三档均命中；缓存状态在同一轮内一致。准备时间单独保存，未计入测试时间。轮间存在缓存状态差异，不将整项任务耗时或轮间差异直接归因于并发数。
- 沿用候选 139 的范围，排除 64 个 `reader_prefetch_slow` 场景；本报告不覆盖该慢测试组的并行稳定性，也不代表全量测试。
- 九次均恰好通过 1,083 项，无跳过的已选用例；根据 JSON reporter 排除内部加载/隐藏事件，比较相对文件路径及完整测试名的排序列表，摘要均为 `f60a0a3e8b536dcbf3e1d5552242d3ca572de5ff6687a8ea9f39b75a7aa2fe2d`。
- 依赖解析后 `pubspec.lock` SHA-256 均为 `0b1722e47859a0a46bb6d1ddddd1c6bfef97e379487b03db3d9964f194ae5a99`；生成数据库代码摘要均为 `33c2f65a1ee66d97898f1907d42f1b0b5f61b2c06a0883cacff8d19f4524480b`。

实际命令仅并发参数不同：

```bash
flutter test --no-pub --reporter expanded \
  --file-reporter=json:reports/tests.json \
  --exclude-tags reader_prefetch_slow --concurrency=N --verbose
```

## 阶段计时、资源与局限

下表为 Flutter verbose 计时器提供的阶段墙钟时间中位数，单位秒。并行时编译与运行可能重叠，**不能将它们相加当作总耗时**；主指标使用 Python 单调时钟包围整个命令，另用 macOS `/usr/bin/time -l` 交叉记录 CPU 和资源数据。

| 并发 | Compile 阶段中位数 | Run 阶段中位数 |
| --- | ---: | ---: |
| 1 | 40.3 | 170.3 |
| 2 | 44.5 | 130.2 |
| 3 | 51.3 | 128.0 |

第三轮并发 2 为 188.2 秒，保留为原始有效样本，没有挑选最快结果替换。其 Compile / Run 阶段分别为 61.7 / 162.5 秒，而第二轮分别为 26.0 / 88.9 秒；多个阶段一起变慢，现有证据无法把差异进一步归因为宿主机 CPU、磁盘或其他负载。

九次资源记录的 swaps 均为 0，未观察到 OOM 或超时。`time -l` 报告的最大 RSS 约 1.37–1.45 GiB，仅作为该工具的资源指标保留，不能当作所有并行子进程的同时总内存。每个 artifact 另保存测试前后 `vm_stat`。每档仅三个样本，报告不保证将来固定提速，也不将观察到的波动直接解释为代码性能回退。

## 复现与归档

- 诊断入口及脚本仅保留在 [实验分支](https://github.com/fy142857/OViewer/tree/codex/ios-test-concurrency-benchmark)，实现提交 `ae211fd`；普通 `build-ios` 在三轮中均为 skipped，没有 APK/IPA 或候选分配。
- 手动触发该分支现有 `build_ios.yml`：`candidate_id=1.11.1+139`、`benchmark_tests=true`、`benchmark_round=1/2/3`、`skip_reader_prefetch_tests=true`。诊断 job 始终 checkout 上述固定源码，`candidate_id` 不改变测量源码。
- 每次任务的 `benchmark-r轮次-c并发` artifact 包含 `environment.json`、`timing.json`、`summary.json`、`tests.json`、`flutter.log`、`resources.txt`，保留 30 天。下载后已验证九个 artifact 均存在且未过期。
- [机器可读结果](benchmarks/ios-test-concurrency/2026-11-01/comparison.json) 保存九次实际计时、测试集合摘要、基础环境、缓存状态、CPU/内存指标、各前置步骤起止时间和 artifact 摘要/到期时间。仅报告及该 JSON 归档至 dev；实验配置不合入日常 CI。
