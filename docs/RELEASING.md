# 版本构建与发布操作

版本策略见 [版本管理方案](VERSION_MANAGEMENT.md)。应用版本由提交类型自动决定；`pubspec.yaml` 是安装包构建读取版本的唯一来源。

## 日常开发

向 `dev` 提交时使用 Conventional Commits，例如 `fix: 修复图片重试`、`feat: 增加阅读选项`。有效变更会启动 **Prepare candidate**，生成如 `1.0.1+2` 的候选，写回版本并触发 Android/iOS 两次构建。仅文档变更不分配新号。

机器人可能已在远端写入版本提交，开始下一次修改前先执行 `git pull --ff-only origin dev`。不要重写候选提交，也不要手动改构建号。

构建结果位于 **Build Android APK** 和 **Build iOS IPA**。运行标题带候选 ID；两个安装包名称仍为 `app-release.apk`、`OViewer.ipa`。`build-metadata` 是校验信息，不是安装包。

构建失败时可重跑该运行，或手动运行对应构建工作流并填写已登记的 `candidate_id`。同一个候选不会重新编号；有代码修改则提交新的候选。

## 候选与台账

`version-state` 分支的 `ledger.json` 保存全局递增编号和候选的源提交、最终构建提交、内容指纹及阶段。请勿手动编辑台账。

分配先写入 `reserved`，再更新开发分支，完成后置为 `ready`。中断后重跑原 **Prepare candidate** 运行会恢复登记的同一提交。目标分支已前进且未包含该候选时，旧任务停止；该编号保留，不回收。

同时准备 `dev` 和 `main` 时使用同一并发组，Git 引用更新还会检查父提交并禁止强制覆盖。GitHub 可能用新的待运行任务取代较早的待运行任务；被替代任务不会分配构建号。

候选版本提交只修改 `pubspec.yaml` 和 `.release/candidate.json`。后者冻结候选摘要及更新日志，最终提交 SHA 存在独立台账，避免自引用。

## 稳定发布

1. 验证 Android/iOS 安装包，记下两次运行的 **run ID**，而非 `#运行序号`。
2. 将已验证候选快进合并至 `main`，推送。相同内容且保留候选提交时复用版本和原构建。
3. 从 `main` 手动运行 **Publish verified candidate**，填写 `version`、`android_run_id`、`ios_run_id`。
4. 建议先保留默认的 `check_only=true`，确认校验通过。正式发布时取消该选项。
5. 发布成功后关闭同版本 Milestone。Issue 完成状态不代表已发布。

发布工作流不编译。它检查运行来源、候选登记、`main` 包含关系、源码及安装包版本、构建号递增、SHA-256 和正式签名，再上传原始产物、`release-manifest.json`、`SHA256SUMS.txt`。上传后的附件还会下载验证，之后才固定标签并公开 Release。

发生中断时保留草稿，使用相同输入重试。仅补齐缺失附件；已存在正式 Release、冲突标签、草稿说明或附件不一致都会停止。不要通过删除附件或移动标签规避检查。产物过期时重新构建同一候选，验证新安装包后再选择新的 run ID；已经有草稿时先核查是否与旧产物冲突。

发布说明取候选源码中的版本条目（如有）或 `Unreleased`，附提交摘要与安装说明。因此，请在准备候选前维护 `CHANGELOG.md`。后续文档修改不会偷偷改变已验证候选的发布说明。

## 签名及本地构建

Android 正式构建需要四项 Actions Secrets：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`，以及仓库变量 `ANDROID_SIGNING_CERT_SHA256`。正式构建缺少配置会失败。PR 验证不读取正式密钥，也不生成可发布候选。

首次配置可在有 `keytool` 与 PyNaCl 的本机运行：

```powershell
python -m scripts.setup_android_signing --directory <仓库外的私密目录> --repository <owner/repo>
```

命令只在首次创建密钥，后续复用；密钥目录包含密码，务必独立备份整个目录并限制访问。不要加入 Git。CI 只在临时目录还原密钥，结束后删除。

普通 `flutter run` 使用 debug 签名。本地 release 构建还需通过环境变量指定 `ANDROID_KEYSTORE_PATH` 和三项密码/别名配置。不要把密码写进命令历史或提交文件。

iOS 仍提供未签名 IPA，部署目标为 iOS 12；需自行签名安装。本地忽略的 iOS 工具已适配候选登记与 `workflow_dispatch`，保留原安装包识别及命名方式。标签不再启动构建或自动安装。

## 验证命令

```text
python -m unittest discover -s scripts/tests -v
python -m scripts.versioning.analyze
flutter test --no-pub
```

静态分析基线位于 `scripts/versioning/analysis-baseline.json`，目前保留已有提示；新增错误和警告会使构建失败。更新基线必须人工审阅，不应在 CI 自动接受新诊断。

自动化无法替代真机验收：需要验证两个递增候选的 Android 覆盖升级及数据保留。Release 安装说明使用当前固定签名的覆盖安装说明及 iOS 签名安装说明。
