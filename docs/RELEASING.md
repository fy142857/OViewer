# 版本构建与发布操作

版本策略见 [版本管理方案](VERSION_MANAGEMENT.md)。应用版本由提交类型自动决定；`pubspec.yaml` 是安装包构建读取版本的唯一来源。

## 日常开发

按维护者约定，后续由自动化助手完成的改动，在完成必要检查后自动提交并推送至 `dev`，无需逐次确认。仅提交本次任务的改动；用户另有明确指示时以该指示为准。此约定不包含正式发布授权。

向 `dev` 提交时使用 Conventional Commits。涉及有效文件的提交必须附带 `Change-Kind` 和 `Change-Reason` 正文项，先按[实际改动分类规则](VERSION_MANAGEMENT.md#应用版本号)区分不兼容变更、新独立能力、修复及原有功能调整；仅有 `feat` 前缀不再直接升级次版本。已有检查更新流程的确认弹窗、提示与持久化调整按 `fix` 处理。有效变更会启动 **Prepare candidate**，生成如 `1.0.1+2` 的候选，写回版本并触发 Android/iOS 两次构建。仅文档变更不分配新号，也无需分类正文项。

正式推送前可用 `python -m scripts.versioning.prepare --branch dev --source <完整提交SHA> --check-only` 核对计划版本及分类；它不分配候选。发现已推送提交误标时，使用 `.release/change-classifications.json` 为精确 SHA 记录正确类别和理由，通过新的候选纠正，不重写原提交或手改版本号。旧候选如不符合当前纠正记录，将被正式发布校验拒绝。

**每次推送后必须检查自动版本提交并同步本地，不能等到下一次修改前才拉取。** 对本次推送的源提交检查 **Prepare candidate**：若正在排队或执行，等待其结束；若因仅修改文档等路径规则未触发，明确确认这一情况。随后执行 `git fetch origin dev main`，在所推送分支上执行对应的 `git pull --ff-only origin dev` 或 `git pull --ff-only origin main`，将远程最新提交（包括自动版本号和候选记录）拉回本地，并确认本地分支与对应远程跟踪分支的差异为 `0 0`。不要重写候选提交，也不要手动改构建号。

候选准备失败或取消时，检查是否已经写回自动版本提交，拉取已存在的最新进度并报告实际失败状态；不能把等待超时或暂时未看到新提交当作检查完成。同步遇到未提交改动或分支分叉时，保留现有工作并处理差异，不得通过强推、重置或丢弃改动强行对齐。开始下一次修改前仍应检查并快进拉取远端新进度。

构建结果位于 **Build Android APK** 和 **Build iOS IPA**。运行标题带候选 ID；两个安装包名称仍为 `app-release.apk`、`OViewer.ipa`。`build-metadata` 是校验信息，不是安装包。

构建失败时可重跑该运行，或手动运行对应构建工作流并填写已登记的 `candidate_id`。同一个候选不会重新编号；有代码修改则提交新的候选。

## 候选与台账

`version-state` 分支的 `ledger.json` 保存全局递增编号和候选的源提交、最终构建提交、内容指纹及阶段。请勿手动编辑台账。

分配先写入 `reserved`，再更新开发分支，完成后置为 `ready`。中断后重跑原 **Prepare candidate** 运行会恢复登记的同一提交。目标分支已前进且未包含该候选时，旧任务停止；该编号保留，不回收。

同时准备 `dev` 和 `main` 时使用同一并发组，Git 引用更新还会检查父提交并禁止强制覆盖。GitHub 可能用新的待运行任务取代较早的待运行任务；被替代任务不会分配构建号。

候选版本提交只修改 `pubspec.yaml` 和 `.release/candidate.json`。后者冻结候选摘要及更新日志，最终提交 SHA 存在独立台账，避免自引用。

## 稳定发布

### 正式发布的工作区约束

- 本地正式发布操作（包括候选晋升、发布校验和触发发布）默认使用当前工作区。
- **未经用户明确授权，禁止新建独立 Git 工作树**，包括执行 `git worktree add`，或通过工具、脚本间接创建。用户要求“正式发布”本身不构成创建工作树的授权；不得以隔离发布、切换 `main` 或保持工作区整洁为由自行创建。
- 当前工作区存在未提交改动或分支冲突时，先检查并保留现有工作。若无法在当前工作区安全继续，应说明具体阻碍，再请求用户决定；不得通过新建工作树绕过问题。
- 此约束针对本地发布操作；现有 GitHub Actions 在运行器中检出候选提交的流程保持不变。

### 发布步骤

1. 验证 Android/iOS 安装包，记下两次运行的 **run ID**，而非 `#运行序号`。
2. 在当前工作区将本地 `dev`、`main` 分别快进同步至各自最新远端，再将 `dev` 的完整提交历史（包括文档及发布记录）快进合并至本地 `main` 并推送。按上述推送后检查规则拉取自动版本提交，确认本地 `dev`、本地 `main`、远端 `dev`、远端 `main` 四者指向同一提交。相同内容且保留候选提交时复用版本和原构建。
3. 从 `main` 手动运行 **Publish verified candidate**，填写 `version`、`android_run_id`、`ios_run_id`。
4. 建议先保留默认的 `check_only=true`，确认校验通过。正式发布时取消该选项。
5. 发布成功后关闭同版本 Milestone。Issue 完成状态不代表已发布。
6. 将本次更新日志归档为正式版本；如产生文档或其他收尾提交，提交并推送至 `dev` 后，必须再次快进同步本地及远端 `main`。等待可能改写分支的候选准备任务结束后，拉取自动版本提交；如仅一侧有新提交，继续快进同步并检查，直到本地及远端的 `dev`、`main` 四个分支 HEAD SHA 完全相同，才算完成正式发布流程。仅应用代码或版本号相同不满足要求。

最终检查执行 `git fetch origin main dev`，比较 `git rev-parse dev main origin/dev origin/main` 的四行 SHA，必须完全相同；同时确认 `git rev-list --left-right --count dev...main`、`git rev-list --left-right --count dev...origin/dev`、`git rev-list --left-right --count main...origin/main` 均为 `0 0`。不能只更新远程跟踪引用，或只执行 `git push origin HEAD:main` 后就结束：这些操作不会自动推进本地 `main` 分支。

分支发生分叉时先解决差异，不得强推覆盖。此四分支一致性要求适用于正式发布前与发布收尾，之后正常开发仍可继续推进 `dev`；日常推送只要求本地所推送分支跟上其对应远端，不因此自动晋升 `main` 或发布 Release。发布标签始终指向已验证安装包的候选提交，不随收尾文档提交移动。

发布工作流不编译。它检查运行来源、候选登记、`main` 包含关系、源码及安装包版本、构建号递增、SHA-256 和正式签名，再上传原始产物、`release-manifest.json`、`SHA256SUMS.txt`。上传后的附件还会下载验证，之后才固定标签并公开 Release。

发生中断时保留草稿，使用相同输入重试。仅补齐缺失附件；已存在正式 Release、冲突标签、草稿说明或附件不一致都会停止。不要通过删除附件或移动标签规避检查。产物过期时重新构建同一候选，验证新安装包后再选择新的 run ID；已经有草稿时先核查是否与旧产物冲突。

发布说明取候选源码中的版本条目（如有）或 `Unreleased`，附提交摘要与安装说明。因此，请在准备候选前维护 `CHANGELOG.md`。后续文档修改不会偷偷改变已验证候选的发布说明。

生成 Release 说明时省略没有正文的章节及其标题，例如空的“变更”“已知限制”；候选提交摘要为空时也省略对应章节。`CHANGELOG.md` 的 `Unreleased` 可以保留空分类作为编写模板。过滤仅作用于最终发布说明，不改写已登记的候选日志或发布清单；已公开说明的修订须由用户明确要求，且不得改动标签、安装包及校验附件。

## 签名及本地构建

Android 正式构建需要四项 Actions Secrets：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`，以及仓库变量 `ANDROID_SIGNING_CERT_SHA256`。正式构建缺少配置会失败。PR 验证不读取正式密钥，也不生成可发布候选。

首次配置可在有 `keytool` 与 PyNaCl 的本机运行：

```powershell
python -m scripts.setup_android_signing --directory <仓库外的私密目录> --repository <owner/repo>
```

命令只在首次创建密钥，后续复用；密钥目录包含密码，务必独立备份整个目录并限制访问。不要加入 Git。CI 只在临时目录还原密钥，结束后删除。

普通 `flutter run` 使用 debug 签名。本地 `flutter run --release` 或 `flutter build apk --release` 可使用 `android/key.properties` 配置已有的正式签名：

```properties
storeFile=C:/path/to/private/oviewer-release.jks
storePassword=<已有密钥库密码>
keyAlias=<已有密钥别名>
keyPassword=<已有密钥密码>
```

`storeFile` 建议使用绝对路径（Windows 使用 `/`）；相对路径以 `android/` 为基准。密钥、别名和密码使用首次配置时保存的同一组数据，不要重新生成密钥。此文件包含密码，已加入 Git 忽略，需限制本机访问权限。

也可使用四项环境变量 `ANDROID_KEYSTORE_PATH`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`。一旦设置其中任意一项，必须完整提供四项，不会与本地文件混用；CI 始终只读取环境变量。缺失配置继续阻止 Release 构建，绝不回退到 debug 签名。不要把密码写进命令历史或提交文件。

iOS 仍提供未签名 IPA，部署目标为 iOS 12；需自行签名安装。本地忽略的 iOS 工具已适配候选登记与 `workflow_dispatch`，保留原安装包识别及命名方式。标签不再启动构建或自动安装。

## 验证命令

```text
python -m unittest discover -s scripts/tests -v
python -m scripts.versioning.analyze
flutter test --no-pub
```

静态分析基线位于 `scripts/versioning/analysis-baseline.json`，目前保留已有提示；新增错误和警告会使构建失败。更新基线必须人工审阅，不应在 CI 自动接受新诊断。

自动化无法替代真机验收：需要验证两个递增候选的 Android 覆盖升级及数据保留。Release 安装说明使用当前固定签名的覆盖安装说明及 iOS 签名安装说明。

## Release 安装包名称

正式发布附件统一使用 `OViewer.apk` 和 `OViewer.ipa`。Android 构建 artifact 仍为 `app-release.apk`，发布时完成校验后仅重命名，不重新编译或签名。发布清单的 `filename` 记录下载名称，`artifact_filename` 记录原构建名称；校验文件使用实际发布名称。
