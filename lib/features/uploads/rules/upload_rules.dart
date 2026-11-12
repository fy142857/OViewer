/// Explanations shown beside upload fields and management actions.
///
/// These describe policy; they do not grant permissions. Mutations must use the
/// capabilities returned by the current management page and server response.
enum UploadRuleId {
  account,
  title,
  category,
  aiDeclaration,
  language,
  translation,
  privateGallery,
  description,
  fileLimits,
  imageDimensions,
  imageIntegrity,
  archives,
  ordering,
  contentChecks,
  rightsAndTerms,
  publication,
  drafts,
  editing,
  cloneUpdate,
  bumpLimit,
  agedGallery,
  deletion,
  disown,
  folders,
  statistics,
  background,
  network,
  recovery,
  bulkActions,
  webHandoff,
  torrents,
}

enum UploadRuleLocation {
  account,
  title,
  category,
  aiDeclaration,
  language,
  translation,
  visibility,
  description,
  files,
  archive,
  ordering,
  publish,
  drafts,
  edit,
  update,
  delete,
  disown,
  folders,
  statistics,
  tasks,
  network,
  bulk,
  webHandoff,
  torrents,
}

enum UploadRuleSeverity { information, caution, danger }

/// Distinguishes website policy from app choices and operating-system limits.
enum UploadRuleKind { website, application, platform }

class UploadRuleText {
  final String zh;
  final String en;

  const UploadRuleText(this.zh, this.en);

  String inLanguage(String languageCode) => languageCode == 'zh' ? zh : en;
}

class UploadRuleSource {
  final UploadRuleText title;
  final String url;

  const UploadRuleSource(this.title, this.url);

  Uri get uri => Uri.parse(url);
}

class UploadRule {
  final UploadRuleId id;
  final List<UploadRuleLocation> locations;
  final UploadRuleText title;
  final UploadRuleText summary;
  final List<UploadRuleText> details;

  /// Consequences that must stay visible even when details are collapsed.
  final List<UploadRuleText> alwaysVisible;
  final List<UploadRuleSource> sources;
  final UploadRuleSeverity severity;
  final UploadRuleKind kind;
  final String checkedOn;

  const UploadRule({
    required this.id,
    required this.locations,
    required this.title,
    required this.summary,
    required this.details,
    required this.sources,
    this.alwaysVisible = const [],
    this.severity = UploadRuleSeverity.information,
    this.kind = UploadRuleKind.website,
    this.checkedOn = '2026-11-12',
  });
}

class UploadRules {
  UploadRules._();

  static UploadRule byId(UploadRuleId id) =>
      all.firstWhere((rule) => rule.id == id);

  static List<UploadRule> forLocation(UploadRuleLocation location) =>
      List.unmodifiable(all.where((rule) => rule.locations.contains(location)));

  static const _uploading = UploadRuleSource(
    UploadRuleText('官方上传指南', 'Official uploading guide'),
    'https://ehwiki.org/wiki/Making_Galleries#Uploading',
  );
  static const _limits = UploadRuleSource(
    UploadRuleText('图片与容量限制', 'Image and gallery limits'),
    'https://ehwiki.org/wiki/Making_Galleries#Limits',
  );
  static const _updating = UploadRuleSource(
    UploadRuleText('画廊更新规则', 'Gallery update rules'),
    'https://ehwiki.org/wiki/Making_Galleries#Updating',
  );
  static const _manager = UploadRuleSource(
    UploadRuleText('官方画廊管理说明', 'Official gallery management guide'),
    'https://ehwiki.org/wiki/My_Galleries',
  );
  static const _managementForm = UploadRuleSource(
    UploadRuleText('官方上传表单', 'Official upload form'),
    'https://upld.e-hentai.org/manage',
  );
  static const _technical = UploadRuleSource(
    UploadRuleText('上传与管理问题说明', 'Uploading and management issues'),
    'https://ehwiki.org/wiki/Technical_Issues#Your_Galleries',
  );
  static const _faq = UploadRuleSource(
    UploadRuleText('上传常见问题', 'Uploading FAQ'),
    'https://ehwiki.org/wiki/E-Hentai_Galleries_FAQ#Uploading',
  );
  static const _terms = UploadRuleSource(
    UploadRuleText('E-Hentai 服务条款', 'E-Hentai Terms of Service'),
    'https://e-hentai.org/tos.php',
  );
  static const _categories = UploadRuleSource(
    UploadRuleText('画廊分类说明', 'Gallery categories'),
    'https://ehwiki.org/wiki/Gallery_Categories',
  );

  static const all = <UploadRule>[
    UploadRule(
      id: UploadRuleId.account,
      locations: [UploadRuleLocation.account],
      title: UploadRuleText('账号与上传资格', 'Account and upload eligibility'),
      summary: UploadRuleText('普通公开上传需要 E-Hentai 论坛账号，无须捐助或额外管理权限。',
          'Ordinary public uploads require an E-Hentai forum account, without a donation or additional moderation power.'),
      details: [
        UploadRuleText('新账号发布的画廊可能先经过人工检查。上传权限、发布限流与是否已经登录是不同的状态。',
            'Galleries from a new account may undergo manual screening. Upload restrictions and publishing rate limits are separate from login status.'),
        UploadRuleText('发布额度会参考近期上传量与历史有效画廊，网站没有公布适用于所有账号的固定次数。限制以当次网站提示为准。',
            'The publishing limit depends on recent uploads and the history of good galleries. There is no published fixed allowance for every account; follow the current website response.'),
        UploadRuleText('受到临时或永久上传限制时，不要通过重复提交或换账号尝试绕过限制。',
            'Do not bypass a temporary or permanent upload restriction by repeatedly submitting or using another account.'),
      ],
      sources: [
        UploadRuleSource(UploadRuleText('上传所需账号', 'Account requirement'),
            'https://ehwiki.org/wiki/Galleries#Making_Galleries'),
        _faq,
        _technical,
      ],
    ),
    UploadRule(
      id: UploadRuleId.title,
      locations: [UploadRuleLocation.title],
      title: UploadRuleText('主标题与原文标题', 'Main and original titles'),
      summary: UploadRuleText('主标题必填；只填写已知信息，不确定的作者、来源或原文标题留空。',
          'A main title is required. Include only known information; leave uncertain creators, sources, or original titles out.'),
      details: [
        UploadRuleText(
            '可参考“[作者] 作品名 [语言] [翻译者]”等与作品类型相符的命名格式。命名规范是建议，不等于所有标题都必须套用同一个模板。',
            'Use the naming style appropriate to the work, such as “[Creator] Title [Language] [Translator]”. The guidelines are recommendations, not one mandatory template for every gallery.'),
        UploadRuleText('原文标题字段按作品实际语言填写；非亚洲作品通常无须填写。不自动翻译或补造作品信息。',
            'Use the work’s actual original language for the original-title field. Non-Asian works generally do not need it. Do not invent or automatically translate identifying information.'),
        UploadRuleText('发布后的标题修改有时间与社区改名限制；请在发布前核对。',
            'Title editing after publication is limited by time and community renaming. Check the title before publishing.'),
      ],
      sources: [
        _uploading,
        UploadRuleSource(UploadRuleText('官方命名规范', 'Official naming guidelines'),
            'https://ehwiki.org/wiki/Renaming'),
      ],
    ),
    UploadRule(
      id: UploadRuleId.category,
      locations: [UploadRuleLocation.category],
      title: UploadRuleText(
          '按实际内容选择分类', 'Choose the category that fits the content'),
      summary: UploadRuleText(
          '同人志、漫画、CG、图集、Non-H、Western、Cosplay 与 Misc 各有适用范围。',
          'Doujinshi, Manga, CG, Image Set, Non-H, Western, Cosplay, and Misc have different purposes.'),
      details: [
        UploadRuleText(
            '同人志适用于自行发行的相关漫画；Manga 对应第三方出版漫画；Artist CG 是按完整套组发行的连续画面或相关套组；Game CG 对应游戏提取画面。',
            'Doujinshi covers relevant self-published comics; Manga covers third-party-published comics. Artist CG is for qualifying sets distributed as a whole; Game CG is for extracted game artwork.'),
        UploadRuleText(
            'Image Set 适用于未构成完整漫画或 CG 作品的散图。亚洲来源的非色情绘画使用 Non-H；西方色情绘画使用 Western；真实角色扮演使用 Cosplay。',
            'Image Set is for loose images that do not form a comic or CG work. Non-H covers non-pornographic drawn Asian content, Western covers pornographic western art, and Cosplay covers qualifying real costume play.'),
        UploadRuleText(
            '3D、AI 生成作品和其他符合站点主题但不适合上述分类的内容通常归入 Misc。分类不能作为绕过内容规定的方式。',
            '3D, AI-generated works, and other permitted material outside those categories generally belong in Misc. A category does not exempt content from site rules.'),
      ],
      sources: [_categories, _terms],
    ),
    UploadRule(
      id: UploadRuleId.aiDeclaration,
      locations: [UploadRuleLocation.aiDeclaration, UploadRuleLocation.publish],
      title: UploadRuleText('AI 生成内容声明', 'AI-generated content declaration'),
      summary: UploadRuleText('按实际情况声明画廊是否主要由 AI 生成内容组成。',
          'Declare accurately whether the gallery primarily consists of AI-generated material.'),
      details: [
        UploadRuleText('不要因图片经过人工筛选、修图或排版就自动把声明改为“非 AI”。应按站点定义判断作品来源。',
            'Manual selection, editing, or layout alone does not determine the declaration. Assess the material under the website’s definitions.'),
        UploadRuleText('反复隐瞒 AI 来源可能导致账号后续上传被强制加上 AI 标记并归入 Misc；应用不能解除这种限制。',
            'Repeated misrepresentation can cause future uploads to receive a compulsory AI indicator and Misc classification. The app cannot remove that account restriction.'),
      ],
      sources: [_uploading, _technical],
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.language,
      locations: [UploadRuleLocation.language],
      title: UploadRuleText('作品语言', 'Language of the work'),
      summary: UploadRuleText('有文字的作品请选择实际语言；只有无文字内容才选择“无文本”。',
          'Choose the actual language for works containing text. Use “No Text” only when appropriate.'),
      details: [
        UploadRuleText('语言描述作品内容，不是当前应用界面语言。发布前检查所选语言与图片是否一致。',
            'This describes the work, not the app’s interface language. Check it against the images before publishing.'),
        UploadRuleText('发布后，上传表单的语言选项不再可用。修改语言需通过站点标签机制；应用不能直接覆盖已经生效的语言标签。',
            'The upload form’s language field is unavailable after publication. Later changes use the website’s tagging system, not an overwrite of established language tags.'),
      ],
      sources: [_uploading],
    ),
    UploadRule(
      id: UploadRuleId.translation,
      locations: [UploadRuleLocation.translation],
      title: UploadRuleText(
          '语言类型与翻译声明', 'Language type and translation declaration'),
      summary: UploadRuleText('正式发行／无文本、翻译和改写分别选择；熟练人工翻译声明只适用于翻译类型。',
          'Choose Official / Textless, Translated, or Rewrite separately. The proficient-human declaration applies only to Translated.'),
      details: [
        UploadRuleText(
            'Official / Textless 表示作品正式以该语言发行，或作品没有文本；Translated 是基于原文的非官方翻译；Rewrite 是使用新编文本的改写，不能当作忠实翻译申报。',
            'Official / Textless means officially published in that language or without text. Translated is a fan translation based on the original text. Rewrite uses newly invented text and should not be declared a faithful translation.'),
        UploadRuleText('第一方自行发布的译本不适用站点的 translated 标记。机器翻译或初学者译文不应声明为熟练人工翻译。',
            'The site’s translated marker does not apply to first-party translations. Machine translations or novice translations should not be declared proficient human translations.'),
        UploadRuleText('持续错误声明可能影响账号今后所有上传的 rough translation 标记处理；不要预先勾选该声明。',
            'Repeated misrepresentation may affect rough-translation tagging on all future uploads. Do not select this declaration by default.'),
      ],
      sources: [_uploading, _managementForm],
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.privateGallery,
      locations: [UploadRuleLocation.visibility, UploadRuleLocation.category],
      title: UploadRuleText('私人／不公开列出', 'Private / Unlisted'),
      summary: UploadRuleText('私人画廊需要相应捐助资格，且不会出现在站内搜索中。',
          'Private galleries require the appropriate donor eligibility and do not appear in site search.'),
      details: [
        UploadRuleText(
            '当前铜星门槛为累计捐助 20 美元。铜星、银星通常每周最多创建 5 个私人画廊，金星及以上通常为 10 个；实际权限以网站为准。',
            'The current Bronze threshold is a cumulative 20 US dollar donation. Bronze and Silver normally permit 5 private galleries per week; Gold or higher normally permits 10. The website determines actual eligibility.'),
        UploadRuleText(
            '私人上传权限可能因滥用被单独收回；星级不保证该功能始终可用，也不能据此计算准确的剩余额度。私人画廊的浏览不产生 GP。',
            'Private-upload access can be separately revoked for abuse. A star does not guarantee availability or an exact remaining quota. Private-gallery views do not generate GP.'),
        UploadRuleText('“不公开列出”不等于经验证的“仅自己可见”或加密存储。不要把敏感文件的保密性寄托于这个名称。',
            '“Unlisted” is not a verified promise of owner-only access or encrypted storage. The name alone does not guarantee confidentiality.'),
        UploadRuleText('私人画廊可以改为公开分类；公开画廊不能再改回 Private。转公开前应再次检查内容和发布后果。',
            'A private gallery can be changed to a public category. A public gallery cannot be changed back to Private. Review the content and consequences before making it public.'),
      ],
      sources: [
        _categories,
        UploadRuleSource(UploadRuleText('捐助等级', 'Donation levels'),
            'https://ehwiki.org/wiki/Donation'),
        UploadRuleSource(UploadRuleText('私人画廊搜索说明', 'Private-gallery search'),
            'https://ehwiki.org/wiki/E-Hentai_Galleries_FAQ#Searching'),
        _updating,
      ],
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.description,
      locations: [UploadRuleLocation.description],
      title: UploadRuleText('画廊描述', 'Gallery description'),
      summary: UploadRuleText('描述可以留空，也可随时修改；单独修改描述不算正式更新。',
          'The description may be blank and can be edited at any time. A description edit alone is not a formal gallery update.'),
      details: [
        UploadRuleText('可说明作品来源、缺失内容、作者或译者信息，以及本次更新增加或修改了什么。',
            'Use it for the source, missing content, creator or translator information, and what an update adds or changes.'),
        UploadRuleText(
            '站点支持有限 BBCode，包括粗体、斜体、下划线、删除线及规定范围内的链接和静态缩略图；不支持任意 HTML。',
            'The site supports limited BBCode, including bold, italic, underline, strike-through, and permitted links and static thumbnails. Arbitrary HTML is not supported.'),
        UploadRuleText('修改描述不会刷新画廊发布时间。描述中的文字也不能代替图片本身来证明某个内容标签适用。',
            'Editing the description does not change the publication timestamp. Description text alone does not establish that a content tag applies to the images.'),
      ],
      sources: [
        UploadRuleSource(
            UploadRuleText('描述格式与用途', 'Description formatting and use'),
            'https://ehwiki.org/wiki/Gallery_Descriptions'),
      ],
    ),
    UploadRule(
      id: UploadRuleId.fileLimits,
      locations: [UploadRuleLocation.files, UploadRuleLocation.archive],
      title: UploadRuleText('文件格式与容量', 'File formats and size limits'),
      summary: UploadRuleText(
          'GIF ≤ 10MB；JPG／WEBP ≤ 20MB；PNG ≤ 50MB。每个画廊最多 2,000 张、总量最多 10GB。',
          'GIF ≤ 10MB; JPG / WEBP ≤ 20MB; PNG ≤ 50MB. A gallery is limited to 2,000 images and 10GB in total.'),
      details: [
        UploadRuleText(
            '限制针对单张图片和整个画廊分别计算，ZIP 压缩后变小不代表包内图片就符合单张限制。网站实际校验结果具有最终效力。',
            'Individual-image limits and the gallery total are separate. A smaller ZIP does not make oversized images valid. The website’s validation is authoritative.'),
        UploadRuleText(
            '超过 2,000 张的完整作品需要合理拆分；按官方规则，除最后一本外，每本应充分使用 2,000 张额度。应用不会自动创建或公开拆分后的画廊。',
            'A complete work exceeding 2,000 images needs suitable splitting. Official guidance requires every gallery except the last to use its full 2,000-image allowance. The app does not automatically create or publish split galleries.'),
        UploadRuleText('超过限制、格式不支持或损坏的文件需处理后再上传；不会为通过检查而默默缩小图片。',
            'Oversized, unsupported, or corrupt files need attention before uploading. Images are not silently reduced to pass validation.'),
      ],
      sources: [_limits],
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.imageDimensions,
      locations: [UploadRuleLocation.files],
      title: UploadRuleText('图片尺寸与动画', 'Image dimensions and animation'),
      summary: UploadRuleText(
          '官方列出的尺寸范围为至少 100×100、最多 20,000×20,000；接近最小尺寸的文件还可能受到额外限制。',
          'The documented dimensions are at least 100×100 and at most 20,000×20,000; files near the minimum can face an additional size condition.'),
      details: [
        UploadRuleText('官方最低尺寸说明还有未明确解释的附加条件。应用不自行把它当成面积或长宽之和计算；以网站实际接收结果为准。',
            'The minimum-dimension wording includes an additional condition whose meaning is not explicit. The app does not assume an area or width-plus-height formula; actual website acceptance is authoritative.'),
        UploadRuleText(
            '动画 GIF 可以上传。APNG 的默认展示不完全支持动画，可能被重采样；保留动画有要求时先检查站点展示效果。',
            'Animated GIFs are permitted. APNG animation is not fully supported in default viewing and may be resampled; check the website result when animation matters.'),
        UploadRuleText(
            '宽度超过 2,400 像素或大小超过 10MB 的图片可能被站点生成缩放、重采样或 WEBP 展示版本。这不意味着应用主动修改了你的源文件。',
            'The website may generate resized, resampled, or WEBP viewing versions for images wider than 2,400 pixels or larger than 10MB. This does not mean the app changed your source file.'),
      ],
      sources: [_limits],
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.imageIntegrity,
      locations: [UploadRuleLocation.files, UploadRuleLocation.publish],
      title: UploadRuleText('保持作品原貌', 'Preserve the work as published'),
      summary: UploadRuleText('完整作品应尽量保持创作者发布时的内容、顺序和画质。',
          'Keep complete works as close as possible to the creator’s published content, order, and quality.'),
      details: [
        UploadRuleText(
            '不要为凑页数加入无关图片，不要无故放大、缩小、重新压缩、遮挡或删减内容。需要格式转换时，先明确确认转换方式并保留原文件。',
            'Do not pad page counts with unrelated images or needlessly upscale, downscale, recompress, obscure, or remove content. Confirm any necessary format conversion and retain the original files.'),
        UploadRuleText(
            '不支持的静态格式可先转换为同尺寸 PNG 并重新校验容量。Live Photo、视频、RAW 与动画不能未经确认就当作普通单帧图片处理。',
            'Unsupported still-image formats can be converted to same-size PNG and rechecked for size. Do not silently treat Live Photos, videos, RAW files, or animations as ordinary single-frame images.'),
        UploadRuleText('若为满足站点限制而转换图片，应在描述中说明，按官方建议在画廊种子中提供原文件。',
            'When converting images to meet site limits, describe the change and follow the official guidance on including originals in the gallery torrent.'),
      ],
      sources: [
        UploadRuleSource(UploadRuleText('保持原发布内容', 'As-published guidance'),
            'https://ehwiki.org/wiki/Making_Galleries#As_Published'),
      ],
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.archives,
      locations: [UploadRuleLocation.archive],
      title: UploadRuleText('ZIP 导入与分批上传', 'ZIP import and upload batches'),
      summary: UploadRuleText('本应用先展开 ZIP 供预览；应用内导入支持 Store／Deflate，不接受加密或分卷包。',
          'The app expands ZIPs for review first. In-app import supports Store / Deflate, not encrypted or split archives.'),
      details: [
        UploadRuleText(
            '官方上传指南列出 ZIP，并禁止加密；某些旧页面仍提到其他格式或更大上传量，不能据此认定本应用支持。其他压缩方法需先解压后导入图片。',
            'The current upload guide lists ZIP and disallows encryption. Older pages mention other formats or larger uploads; that does not establish app support. Extract other compression methods before importing the images.'),
        UploadRuleText('检查展开后的图片数、容量和顺序。嵌套压缩包不会递归解压；路径越界、符号链接或损坏条目不能直接作为图片导入。',
            'Check the expanded image count, size, and order. Nested archives are not recursively expanded; escaping paths, symbolic links, and corrupt entries are not accepted as images.'),
        UploadRuleText(
            '为减少后台等待，确认后的图片可无损组成小批次 ZIP 串行上传，默认每批不超过 100MB。内部打包不会重新压缩图片内容。',
            'Confirmed images may be grouped into sequential ZIP batches of up to 100MB to reduce background scheduling delays. This packaging does not recompress image contents.'),
        UploadRuleText('本地可能同时需要 ZIP、展开图片和上传请求体的空间。空间不足时先释放空间，不要删除仍在使用的上传文件。',
            'Storage may be needed for the source ZIP, expanded images, and prepared uploads at the same time. Free space when needed without deleting files used by active uploads.'),
      ],
      sources: [
        UploadRuleSource(UploadRuleText('官方 ZIP 指南', 'Official ZIP guide'),
            'https://ehwiki.org/wiki/Making_Galleries#Archives'),
        _technical,
      ],
      kind: UploadRuleKind.application,
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.ordering,
      locations: [UploadRuleLocation.ordering, UploadRuleLocation.files],
      title: UploadRuleText('文件名、顺序与重复项', 'Filenames, order, and duplicates'),
      summary: UploadRuleText('上传前核对原名、上传名和页序；同名不代表同一图片，调整页面顺序也不等于修改下载文件名。',
          'Review original names, upload names, and page order. Matching names do not prove matching images, and reordering pages does not rename downloaded files.'),
      details: [
        UploadRuleText(
            '网站对非 ASCII 文件名的处理可能造成乱码或遗漏。本应用在预览中显示实际上传名，使用编号和可用的 ASCII 名称，原始文件不改名。',
            'The website’s handling of non-ASCII filenames can cause garbling or omissions. The preview shows numbered ASCII upload names without renaming your original files.'),
        UploadRuleText('自然排序按数字顺序处理 2、10 等名称；字典排序按文字顺序处理。手动拖动后保持人工顺序，除非再次主动排序。',
            'Natural sort treats numbers such as 2 and 10 numerically; lexical sort follows text order. Manual order is preserved until you explicitly sort again.'),
        UploadRuleText(
            '同名不同内容需要不同上传名。完全重复的内容会提示检查，不能只根据文件名或缩略图判断、覆盖或删除。站点也可能移除重复图片，上传后还需核对实际页数。',
            'Different images with the same name need distinct upload names. Review exact-content duplicates rather than deciding by name or thumbnail. The website may remove duplicates, so verify the actual page count afterward.'),
      ],
      sources: [_uploading, _technical],
      kind: UploadRuleKind.application,
    ),
    UploadRule(
      id: UploadRuleId.contentChecks,
      locations: [UploadRuleLocation.publish],
      title: UploadRuleText('发布前检查内容', 'Check the content before publishing'),
      summary: UploadRuleText('检查重复上传、禁发名单、分类、作品完整性及页数是否适合该类作品。',
          'Check for existing uploads, prohibited content, correct classification, completeness, and a suitable image count.'),
      details: [
        UploadRuleText('先用标题、作者、标签等检索已有内容。重复或较差版本可能被剔除；换文件名不等于新作品。',
            'Search by title, creator, or tags for existing content. Duplicate or inferior versions may be expunged; renaming files does not create a new work.'),
        UploadRuleText(
            '一般散图型画廊要求至少 8 张，完整作品、样本或持续连载等存在例外。不要把“所有作品至少 8 张”作为统一要求，也不要用无关图片凑数。',
            'Imageset-style galleries generally require at least 8 images, with exceptions for complete works, samples, or ongoing works. There is no universal eight-image rule for every work; do not add unrelated padding.'),
        UploadRuleText(
            '不同作品或不应混放的内容可能构成不合规合集。包含真人的内容、违法内容及禁发名单所列内容另有严格限制，应阅读官方条款。',
            'Combining separate works or incompatible material can create an unacceptable compilation. Real-person material, illicit content, and prohibited publishers or creators have additional strict rules; read the official terms.'),
        UploadRuleText('应用不会自动判断版权、作品完整性或内容是否获准发布，也不会把本地文件检查通过显示为站点审核通过。',
            'The app does not determine copyright, completeness, or permission to publish. Passing local file checks is not website approval.'),
      ],
      sources: [
        _faq,
        UploadRuleSource(
            UploadRuleText('内容与剔除规则', 'Content and expunging rules'),
            'https://ehwiki.org/wiki/Expunging'),
        _terms,
      ],
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.rightsAndTerms,
      locations: [UploadRuleLocation.publish, UploadRuleLocation.files],
      title: UploadRuleText('传播权利与服务条款', 'Distribution rights and site terms'),
      summary: UploadRuleText('上传前应确认你有权传播内容，并阅读、主动同意原站服务条款。',
          'Before uploading, confirm your right to distribute the material and actively agree to the website’s Terms of Service.'),
      alwaysVisible: [
        UploadRuleText('公开发布后不能通过普通删除操作撤回画廊；平台授权涉及持续使用和传播。',
            'Public publication cannot be undone through ordinary gallery deletion; the site’s license covers continuing use and distribution.'),
      ],
      details: [
        UploadRuleText('拥有原文件、购买过作品或声明“版权归原作者”不自动等于获得传播授权。以实际权利和服务条款为准。',
            'Possessing a file, buying a work, or saying “copyright belongs to the creator” does not by itself grant distribution permission. Follow your actual rights and the site terms.'),
        UploadRuleText('条款保留上传者原有权利，同时要求授予平台及用户相应使用许可。不要把保留版权理解为随时可以撤回公开内容。',
            'The terms retain existing ownership rights while requiring licenses for the service and its users. Retaining copyright does not imply that public content can be withdrawn at will.'),
        UploadRuleText('禁发名单会变化，发布前应打开官方名单核对。应用的规则说明不是完整名单，也不能替代原站条款。',
            'The prohibited-content list can change. Check the official list before publication; these explanations are not the complete list and do not replace the terms.'),
      ],
      sources: [
        _terms,
        UploadRuleSource(
            UploadRuleText('禁发内容与作者名单', 'Prohibited content and artists'),
            'https://forums.e-hentai.org/index.php?showtopic=19797'),
      ],
      severity: UploadRuleSeverity.danger,
    ),
    UploadRule(
      id: UploadRuleId.publication,
      locations: [UploadRuleLocation.publish],
      title: UploadRuleText('确认发布', 'Confirm publication'),
      summary: UploadRuleText('上传完成只会进入待核对草稿；确认远端内容后再手动发布。',
          'A finished upload remains a draft for review. Publish manually after checking the content received by the website.'),
      alwaysVisible: [
        UploadRuleText('公开画廊不能直接删除，也不能改回 Private。私人画廊转公开同样需要确认。',
            'Public galleries cannot be directly deleted or changed back to Private. Making a private gallery public requires the same review.'),
      ],
      details: [
        UploadRuleText('逐项检查标题、分类、可见性、远端页数、首尾页和排序。字节发送到 100% 不代表网站已经接收和处理完成。',
            'Check the title, category, visibility, remote page count, first and last pages, and order. Sending 100% of the bytes does not mean the website has accepted and processed them.'),
        UploadRuleText('新画廊可能仍在处理或审核，暂时搜索不到不代表发布失败。不要因此重复创建或重复发布。',
            'A new gallery may still be processing or awaiting screening. Absence from search is not proof of failure and is not a reason to create or publish it again.'),
      ],
      sources: [_manager, _updating, _faq],
      kind: UploadRuleKind.application,
      severity: UploadRuleSeverity.danger,
    ),
    UploadRule(
      id: UploadRuleId.drafts,
      locations: [UploadRuleLocation.drafts, UploadRuleLocation.edit],
      title: UploadRuleText('本地草稿与站内草稿', 'Local drafts and website drafts'),
      summary: UploadRuleText('保存到本机不等于保存到站点；未发布的站内草稿存在保留期限。',
          'Saving on this device is not the same as saving to the website. Unpublished website drafts have a retention period.'),
      details: [
        UploadRuleText(
            '未发布画廊在 365 天未更新后会从管理器移除。站点保存操作可以重新开始这段保留期，单纯修改本地草稿不能续期。',
            'Unpublished galleries are removed from the manager after 365 days without an update. Saving on the website resets that period; editing only the local draft does not.'),
        UploadRuleText('网站文件上传会自动保存；资料等其他修改需要保存。页面会分别标记本地修改与已确认的站内状态。',
            'Uploaded files are saved by the website automatically; other changes require saving. Local edits and confirmed website state are shown separately.'),
        UploadRuleText('离开编辑页保留本地草稿，不会自动公开或替站内草稿续期。清理本地草稿也不会删除站内画廊。',
            'Leaving the editor retains the local draft without publishing it or renewing the website draft. Clearing a local draft does not delete a website gallery.'),
      ],
      sources: [_uploading],
    ),
    UploadRule(
      id: UploadRuleId.editing,
      locations: [
        UploadRuleLocation.edit,
        UploadRuleLocation.title,
        UploadRuleLocation.category
      ],
      title: UploadRuleText('发布后的编辑权限', 'Editing after publication'),
      summary: UploadRuleText('标题和分类通常有发布后 24 小时等限制；可编辑项以当次管理页为准。',
          'Title and category editing generally have limits such as the first 24 hours after publication. The current management page determines what is editable.'),
      details: [
        UploadRuleText('成功的社区改名申请会影响上传者修改标题的能力。社区已改分类、公开父画廊的子版本等情况也可能不能直接修改分类。',
            'A successful community rename affects the uploader’s ability to edit the title. Community reclassification and child galleries with public parents can also restrict direct category editing.'),
        UploadRuleText('私人画廊可以随时改变分类，但公开画廊不能改成 Private。发布后的语言调整通过标签机制进行。',
            'Private galleries can change category at any time, but public galleries cannot become Private. Language changes after publication use the tagging system.'),
        UploadRuleText('客户端时间、星级或本地计数不能代替网站授权。按钮不可用时查看具体原因；需要社区处理的修改请使用官方入口。',
            'Device time, donor status, and local counters do not grant website permission. Read the reason for an unavailable action and use the official route for changes requiring community action.'),
      ],
      sources: [_updating],
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.cloneUpdate,
      locations: [UploadRuleLocation.update],
      title: UploadRuleText('通过新版本更新图片', 'Update images through a new version'),
      summary: UploadRuleText('已发布画廊增删或重排图片，需要先克隆／解锁，再发布更新版本。',
          'Adding, removing, or reordering images in a published gallery requires cloning / unlocking and publishing an updated version.'),
      details: [
        UploadRuleText('新版本发布后替换旧版本并获得新的时间戳；同一画廊链通常继承标签、收藏、评分、描述和评论。',
            'Publishing the child replaces the previous version and gives it a new timestamp. The gallery chain retains tags, favorites, ratings, description, and comments.'),
        UploadRuleText('先在新版本中检查变更，建议在描述中说明新增或修正内容。创建更新草稿不等于已经发布该版本。',
            'Review changes in the new version and describe additions or fixes. Creating an update draft does not publish it.'),
        UploadRuleText('老化、站点锁定或版本已被替换时可能无法更新。不要把重新上传为独立画廊当成原版本的无损更新。',
            'Aging, a website lock, or replacement of the version may prevent updating. A separate reupload is not an update that preserves the old chain.'),
      ],
      sources: [_updating, _manager],
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.bumpLimit,
      locations: [UploadRuleLocation.update],
      title: UploadRuleText('更新次数与例外', 'Update frequency and exceptions'),
      summary: UploadRuleText('公开画廊通常在 30 天内更新超过 2 次后受到限制，但存在有效更新的例外。',
          'Public galleries generally face restrictions after more than 2 updates in 30 days, with exceptions for valid updates.'),
      details: [
        UploadRuleText('作者图集的有效新增、持续连载或翻译项目按实际发布进度增加内容，以及修复可被剔除的问题，属于官方列出的例外。',
            'Official exceptions include valid additions to artist galleries, ongoing works or translations following actual releases, and fixes for expungeable problems.'),
        UploadRuleText('通常的次数限制不适用于未发布草稿和私人画廊。应用不会只凭本地次数自动拒绝，也不会承诺符合例外就一定获准。',
            'The usual frequency limit does not apply to unpublished or private galleries. The app does not reject solely on a local count or guarantee that an asserted exception will be accepted.'),
        UploadRuleText('服务器返回更新锁定时显示原站原因；不要反复提交或新建画廊绕过限制。',
            'When the server locks updates, read its explanation rather than repeatedly submitting or creating another gallery to bypass it.'),
      ],
      sources: [_updating, _technical],
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.agedGallery,
      locations: [UploadRuleLocation.update, UploadRuleLocation.edit],
      title: UploadRuleText('老化画廊', 'Aged galleries'),
      summary: UploadRuleText('距最后一次发布达到 365 天的老化画廊不能继续修改图片。',
          'An aged gallery, 365 days after its last publication, can no longer have its files modified.'),
      details: [
        UploadRuleText('这里按最后一次发布计算，与站内草稿的 365 天保留规则不同，也不是按本地创建时间计算。',
            'This is measured from the last publication, not local creation, and is separate from the 365-day retention rule for unpublished drafts.'),
        UploadRuleText('必要修改需要重新上传并通过官方替换流程处理旧画廊；新上传是新画廊链，不继承旧链的全部元数据。',
            'Necessary changes require a new upload and the official replacement process for the old gallery. The new upload starts a new chain without the old chain’s metadata.'),
      ],
      sources: [_technical],
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.deletion,
      locations: [UploadRuleLocation.delete, UploadRuleLocation.bulk],
      title: UploadRuleText('删除的范围', 'What deletion affects'),
      summary: UploadRuleText('站内删除通常只适用于未发布或私人画廊；公开画廊不能直接删除。',
          'Website deletion is generally available only for unpublished or private galleries. Public galleries cannot be directly deleted.'),
      alwaysVisible: [
        UploadRuleText('“移除本地任务”不会删除站内画廊；“删除站内画廊”是另一个操作。两者都不会删除你选择的原始文件。',
            '“Remove local task” does not delete the website gallery. “Delete website gallery” is a separate action. Neither deletes the original files you selected.'),
      ],
      details: [
        UploadRuleText('删除站内草稿或私人画廊前，核对标题、数量与账号。公开画廊即使混在批量选项中，也不能获得删除权限。',
            'Check the titles, count, and account before deleting website drafts or private galleries. Including a public gallery in a bulk selection does not make it deletable.'),
        UploadRuleText('删除请求结果不明时先刷新核对，不要重复发送。已经成功的远端删除不能通过撤销本地任务自动恢复。',
            'If a deletion result is uncertain, refresh and reconcile before submitting again. Undoing a local task does not restore a successful remote deletion.'),
      ],
      sources: [_manager],
      severity: UploadRuleSeverity.danger,
    ),
    UploadRule(
      id: UploadRuleId.disown,
      locations: [UploadRuleLocation.disown, UploadRuleLocation.bulk],
      title: UploadRuleText(
          '放弃管理与署名（Disown）', 'Disown: relinquish management and attribution'),
      summary: UploadRuleText('Disown 不是删除画廊，也不是暂时隐藏。',
          'Disowning does not delete the gallery or temporarily hide it.'),
      alwaysVisible: [
        UploadRuleText('操作后画廊立即从管理列表移除，你会立即失去编辑权；画廊内容仍然存在。',
            'The gallery immediately leaves your manager and you immediately lose editing access. Its content remains available.'),
        UploadRuleText('发布未满一周时，署名需到发布满一周才移除；已满一周则立即移除。',
            'For a gallery published less than a week ago, attribution is removed once a week has passed since publication; otherwise it is removed immediately.'),
      ],
      details: [
        UploadRuleText('放弃管理后的画廊仍可按原规则产生 GP。应用没有即时撤销按钮。',
            'A disowned gallery can still generate GP under the normal rules. The app has no instant undo.'),
        UploadRuleText(
            '误操作只能通过官方 Report Gallery 中的 Reversion/Split/Undisown Request 申请恢复；提交申请不保证即时恢复。',
            'For a mistake, use “Reversion/Split/Undisown Request” under the official Report Gallery form. A request does not guarantee immediate restoration.'),
      ],
      sources: [_manager],
      severity: UploadRuleSeverity.danger,
    ),
    UploadRule(
      id: UploadRuleId.folders,
      locations: [UploadRuleLocation.folders],
      title: UploadRuleText('管理目录', 'Management folders'),
      summary: UploadRuleText('目录只整理你自己的上传列表，不会创建公开合集或改变他人的浏览方式。',
          'Folders organize your own upload list; they do not create public collections or change other users’ browsing.'),
      details: [
        UploadRuleText('未归类画廊位于 Unsorted。官方指南列出的自建目录上限为 250，实际创建结果以网站为准。',
            'Unfiled galleries are in Unsorted. The official guide lists a limit of 250 user-created folders; the website determines actual availability.'),
        UploadRuleText('批量移动前核对目标目录。删除非空目录前先明确迁移其中画廊；删除目录不应被当作删除画廊。',
            'Check the destination before a bulk move. Explicitly move galleries before deleting a nonempty folder; folder deletion is not gallery deletion.'),
      ],
      sources: [_manager, _uploading],
    ),
    UploadRule(
      id: UploadRuleId.statistics,
      locations: [UploadRuleLocation.statistics],
      title: UploadRuleText('统计并非实时更新', 'Statistics are not real-time'),
      summary: UploadRuleText('访问、命中和榜单记录由站点统计，通常存在数小时延迟。',
          'Visits, hits, and toplist records come from the website and can be delayed by several hours.'),
      details: [
        UploadRuleText('官方技术说明称画廊统计约每 4 小时更新。刚发布或刚有人访问时显示零，不一定表示上传或计数失败。',
            'The official technical guide says gallery statistics update approximately every 4 hours. Zero immediately after publishing or a visit does not necessarily indicate a failure.'),
        UploadRuleText('页面显示的刷新时间是应用取得数据的时间，不是站点刚刚完成计数的保证。私人画廊浏览不产生 GP。',
            'The displayed refresh time is when the app fetched the data, not a guarantee that the site just recalculated it. Private-gallery views do not generate GP.'),
      ],
      sources: [_manager, _technical, _categories],
    ),
    UploadRule(
      id: UploadRuleId.background,
      locations: [UploadRuleLocation.tasks],
      title:
          UploadRuleText('后台上传与系统中断', 'Background uploads and interruptions'),
      summary: UploadRuleText('已准备好的上传可在切后台或锁屏后继续；系统仍可能暂停或延后任务。',
          'Prepared uploads can continue when the app is backgrounded or the device is locked; the system can still pause or delay them.'),
      alwaysVisible: [
        UploadRuleText('强制退出或在系统中停止应用后，不保证继续上传。重新打开后先核对远端结果再恢复。',
            'Uploads are not guaranteed to continue after force-quitting or stopping the app in system controls. Reopen the app and reconcile remote results before resuming.'),
      ],
      details: [
        UploadRuleText('文件导入、解压和上传准备与实际传输是不同阶段。准备尚未完成时切到后台，准备过程可能暂停。',
            'Importing, extracting, and preparing files are separate from transfer. Backgrounding before preparation finishes can pause that stage.'),
        UploadRuleText(
            'iOS 的后台调度可能让下一批上传延后启动；用户强制退出会停止后台传输。Android 的系统停止、省电或设备状态也可能中断任务。',
            'iOS may delay the next background batch, and force-quitting stops background transfers. Android system stops, power management, or device conditions can also interrupt work.'),
        UploadRuleText('后台不会自动公开发布。传输完成后仍需返回应用核对并确认发布。',
            'Background transfer does not publish automatically. Return to review and confirm publication.'),
      ],
      sources: [
        UploadRuleSource(
            UploadRuleText('Android 后台传输说明', 'Android background transfer'),
            'https://developer.android.com/develop/background-work/background-tasks/uidt'),
        UploadRuleSource(
            UploadRuleText('Apple 后台传输说明', 'Apple background transfer'),
            'https://developer.apple.com/documentation/foundation/downloading-files-in-the-background'),
      ],
      kind: UploadRuleKind.platform,
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.network,
      locations: [UploadRuleLocation.network, UploadRuleLocation.tasks],
      title: UploadRuleText('网络与流量', 'Network and data usage'),
      summary: UploadRuleText('默认跟随当前网络，包含移动数据；开始前检查总大小和当前网络。',
          'Uploads follow the current network by default, including mobile data. Check the total size and current network before starting.'),
      details: [
        UploadRuleText('此选项限制后台图片批次传输；打开页面及准备草稿时的表单读取、创建和保存仍使用当前网络。',
            'This option limits background image-batch transfers. Reading forms and creating or saving draft details still use the current network.'),
        UploadRuleText(
            '可选择仅 Wi-Fi。Android 根据当前实际网络判断，计费 Wi-Fi 也属于 Wi-Fi；不因蜂窝网络免费或未计费就放行。无法确认网络条件时暂停，发送开始后发现条件变化会停止并要求核对接收结果，不自动重传。',
            'Wi-Fi only on Android checks the actual current network. Metered Wi-Fi qualifies; free or unmetered cellular does not. An unknown network pauses the task. A change after sending starts stops the transfer and requires receipt review, without automatic retransmission.'),
        UploadRuleText(
            '部分旧版 Android（API 21–27）和 VPN 无法报告底层网络。仅 Wi-Fi 模式下会等待；如需改用当前网络，先停止尚未发送的任务，再回草稿关闭该选项重新提交。应用不会为检测 Wi-Fi 绕过 VPN 或代理。',
            'Some older Android versions (API 21–27) and VPNs cannot report the underlying network. Wi-Fi-only tasks wait in that case. To use the current network, stop an unsent task, turn off this option in its draft, and submit again. The app does not bypass the VPN or proxy to find Wi-Fi.'),
        UploadRuleText(
            'iOS 使用系统的禁止蜂窝连接策略，有线网络仍可能被允许。两平台均无法识别 Wi-Fi 热点上游是否使用手机流量；网络切换通知也可能有延迟，不能承诺任意第三方 VPN 切换瞬间绝无蜂窝流量。',
            'iOS uses the system policy that disallows cellular connections; wired networks may still be allowed. Neither platform identifies mobile data used upstream by a Wi-Fi hotspot. Network-change notifications can be delayed, so no zero-cellular-byte guarantee is made for an instant transition inside any third-party VPN.'),
        UploadRuleText('上传遵循当前有效代理设置；代理不可用或后台不支持当前配置时会提示等待，不会悄悄改为直连。',
            'Uploads use the active proxy policy. If a proxy is unavailable or its configuration is unsupported in the background, the task waits with an explanation instead of silently connecting directly.'),
        UploadRuleText('同一账号的上传批次串行进行，避免站点同时处理多处上传时出现遗漏或锁冲突。',
            'Upload batches for an account run sequentially to avoid omissions or locks caused by simultaneous uploads.'),
      ],
      sources: [
        _technical,
        UploadRuleSource(
            UploadRuleText('Android VPN 网络信息', 'Android VPN network reporting'),
            'https://developer.android.com/about/versions/pie/android-9.0-changes-all#vpn'),
        UploadRuleSource(
            UploadRuleText('iOS 蜂窝连接限制', 'iOS cellular connection policy'),
            'https://developer.apple.com/documentation/foundation/urlsessionconfiguration/allowscellularaccess'),
      ],
      kind: UploadRuleKind.application,
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.recovery,
      locations: [UploadRuleLocation.tasks],
      title: UploadRuleText('上传进度与恢复', 'Upload progress and recovery'),
      summary: UploadRuleText('“已发送”“站点处理中”“已确认接收”和“已发布”是不同状态。',
          '“Sent”, “processing on the website”, “receipt confirmed”, and “published” are different states.'),
      details: [
        UploadRuleText('恢复按站点已确认的图片或批次进行，不承诺从中断字节直接续传。结果不明时先核对，必要时重传整个未确认批次。',
            'Recovery uses images or batches confirmed by the website, not a promised byte-level resume. Reconcile uncertain results first; an unconfirmed batch may need complete retransmission.'),
        UploadRuleText(
            '仅凭名称、大小或缩略图不能证明服务器已经接收同一文件。创建、发布、删除或放弃管理的请求结果不明时，不能自动重复发送。',
            'A name, size, or thumbnail alone does not prove receipt of the same file. Uncertain create, publish, delete, or disown requests must not be replayed automatically.'),
        UploadRuleText('退出登录会停止后续上传。已发送的请求仍可能被站点接收；重新登录同一账号后先核对，其他账号不能继续这些任务。',
            'Signing out stops further uploads. Already-sent requests may still be accepted; reconcile after signing into the same account. Another account cannot continue those tasks.'),
      ],
      sources: [_technical],
      kind: UploadRuleKind.application,
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.bulkActions,
      locations: [UploadRuleLocation.bulk],
      title:
          UploadRuleText('批量操作逐项生效', 'Bulk actions take effect item by item'),
      summary: UploadRuleText('确认前核对目标清单、账号、数量和操作；每个画廊仍需具备相应权限。',
          'Review the target list, account, count, and action before confirming. Each gallery still needs the corresponding permission.'),
      alwaysVisible: [
        UploadRuleText('批量操作可能部分成功。停止只会阻止尚未发送的操作，不会撤销已成功或已发送的请求。',
            'A bulk action can partially succeed. Stopping prevents unsent actions; it does not undo completed or already-sent requests.'),
      ],
      details: [
        UploadRuleText('默认全选只包含已加载条目。跨页选择必须先取得并展示完整目标清单，确认后不会自动加入新出现的画廊。',
            'Select all covers loaded entries by default. Cross-page selection must first fetch and show the complete list; galleries appearing later are not silently added after confirmation.'),
        UploadRuleText('执行前再次检查每项状态。权限变化会说明跳过原因；登录失效、限流、锁冲突或结果不明会停止剩余队列并要求核对。',
            'Each item is checked again before execution. Changed permissions produce a skip reason; expired login, rate limits, lock conflicts, or uncertain results stop the remaining queue for review.'),
        UploadRuleText('批量发布、私人转公开、删除与 Disown 分别展示各自后果，不能用一次笼统确认混合执行。',
            'Bulk publication, making private galleries public, deletion, and disowning each show their own consequences. One generic confirmation must not combine them.'),
      ],
      sources: [_manager, _technical],
      kind: UploadRuleKind.application,
      severity: UploadRuleSeverity.danger,
    ),
    UploadRule(
      id: UploadRuleId.webHandoff,
      locations: [UploadRuleLocation.webHandoff],
      title: UploadRuleText('在官方网页继续管理', 'Continue on the official website'),
      summary: UploadRuleText('网页与应用内界面操作同一份站内画廊；切换前先完成保存并暂停相关上传。',
          'The website and in-app screen manage the same remote gallery. Save and pause relevant uploads before switching.'),
      details: [
        UploadRuleText('不要同时在应用、多个网页或不同设备中修改同一画廊。返回应用后会重新读取站内状态，再继续应用内操作。',
            'Avoid editing the same gallery in the app, multiple pages, or different devices at once. The app reloads website state before further in-app operations.'),
        UploadRuleText('网页可用于种子管理、标签或改名申请、申诉及未支持的官方功能。网页入口不代表应用拥有更高的账号权限。',
            'Use the website for torrent management, tagging or rename requests, appeals, and unsupported official features. Opening it does not grant additional account permissions.'),
        UploadRuleText('网页返回时可能发现他处修改；需要核对差异，不能自动覆盖远端版本。网页登录失效时使用应用的登录入口重新验证。',
            'Changes made elsewhere may be found on return. Review differences rather than automatically overwriting them. If the website session expires, use the app’s login route to verify again.'),
      ],
      sources: [_manager, _technical],
      kind: UploadRuleKind.application,
      severity: UploadRuleSeverity.caution,
    ),
    UploadRule(
      id: UploadRuleId.torrents,
      locations: [UploadRuleLocation.torrents],
      title: UploadRuleText('种子是独立功能', 'Torrents are a separate feature'),
      summary: UploadRuleText('上传画廊图片不等于创建种子或持续做种；种子管理通过官方网页进行。',
          'Uploading gallery images does not create a torrent or seed it. Manage torrents on the official website.'),
      details: [
        UploadRuleText('画廊发布后可以通过站点的种子窗口提交相关种子；提交者不必是画廊原上传者。种子有独立的上传限制与规则。',
            'After publication, relevant torrents can be submitted through the website’s torrent window. The submitter need not be the original gallery uploader. Torrents have separate limits and rules.'),
        UploadRuleText('上传者可删除自己的种子；删除或剔除画廊并不保证种子停止传播。需要提供原文件时，阅读官方种子及做种要求。',
            'Torrent uploaders can delete their own torrents. Deleting or expunging a gallery does not guarantee that torrent distribution stops. Read the official torrent and seeding requirements when providing original files.'),
      ],
      sources: [
        UploadRuleSource(UploadRuleText('EHTracker 规则', 'EHTracker rules'),
            'https://ehwiki.org/wiki/EHTracker'),
      ],
    ),
  ];
}
