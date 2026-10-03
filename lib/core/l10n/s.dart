import '../../models/daily_check_in.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../blocs/settings/settings_bloc.dart';

/// Simple map-based localization. Supports zh (Chinese) and en (English).
/// Usage: `S.of(context).settings`
class S {
  static S of(BuildContext context) {
    final locale = context.read<SettingsBloc>().state.locale;
    return S._(locale);
  }

  final String _l;
  S._(this._l);

  bool get _zh => _l == 'zh';

  String get autoCheckIn => _zh ? '自动签到' : 'Automatic check-in';
  String get dailyCheckIn => _zh ? '今日签到' : 'Daily check-in';
  String get checkInNow => _zh ? '手动签到' : 'Check in';
  String get checkInSuccess => _zh ? '签到成功' : 'Check-in successful';
  String get checkInDismiss => _zh ? '确定' : 'OK';
  String get checkInConfirmed => _zh ? '已收到站点的每日奖励确认。' : 'The site confirmed your daily reward.';
  String get checkInSchedule => _zh ? '使用应用时自动签到，每日北京时间 08:00 重置' : 'Checks in while using the app. Resets daily at 00:00 UTC.';
  String get checkInStorageError => _zh ? '签到设置或记录保存失败，请重试' : 'Could not save check-in settings or status. Please retry.';
  String checkInStatus(CheckInStatus status) {
    switch (status) {
      case CheckInStatus.signedOut: return _zh ? '未登录' : 'Not signed in';
      case CheckInStatus.pending: return _zh ? '待签到' : 'Not checked in yet';
      case CheckInStatus.running: return _zh ? '签到中' : 'Checking in';
      case CheckInStatus.confirmed: return _zh ? '今日已签到' : 'Checked in today';
      case CheckInStatus.unconfirmed: return _zh ? '已尝试，未确认领取；可能已在其他设备领取' : 'Attempted, but not confirmed. You may have claimed the reward on another device.';
      case CheckInStatus.failed: return _zh ? '请求失败，请重试（重试间隔 30 秒）' : 'Request failed. Retry after 30 seconds.';
    }
  }

  String get lowerCacheLimitWarning => _zh ? '调低限制后，自动清理超出部分！' : 'Lowering the limit will automatically remove excess cached images!';
  String get cacheLimitApplyFailed => _zh ? '缓存限制设置或清理失败，请重试' : 'Could not apply the cache limit or finish cleanup. Please retry.';
  String get cacheQuotaFailed => _zh ? '自动清理失败，点击重试' : 'Automatic cleanup failed. Tap to retry';

  String get gidMatch => _zh ? 'GID 匹配' : 'GID match';
  String get gidNotFound =>
      _zh ? '未找到可访问的 GID 匹配' : 'No accessible GID match found';
  String get ordinarySearchFailed => _zh ? '关键词搜索失败' : 'Keyword search failed';
  String get gidSearchFailed => _zh ? 'GID 查找失败' : 'GID lookup failed';
  String get searchPageFailed =>
      _zh ? '加载更多结果失败' : 'Failed to load more results';
  String get searchIncomplete =>
      _zh ? '搜索未完成，请重试失败的查询' : 'Search incomplete. Retry the failed query.';

  // ---- Common ----
  String get cancel => _zh ? '取消' : 'Cancel';
  String get confirm => _zh ? '确认' : 'Confirm';
  String get save => _zh ? '保存' : 'Save';
  String get clear => _zh ? '清除' : 'Clear';
  String get delete => _zh ? '删除' : 'Delete';
  String get retry => _zh ? '重试' : 'Retry';
  String get reloadLoginPage => _zh ? '刷新登录页' : 'Reload login page';
  String get login => _zh ? '登录' : 'Login';
  String get logout => _zh ? '退出登录' : 'Logout';
  String get reset => _zh ? '重置' : 'Reset';
  String get submit => _zh ? '提交' : 'Submit';
  String get download => _zh ? '下载' : 'Download';
  String get remove => _zh ? '移除' : 'Remove';

  // ---- Home Screen ----
  String get tabLatest => _zh ? '最新' : 'Latest';
  String get tabPopular => _zh ? '热门' : 'Popular';
  String get tabHistory => _zh ? '历史' : 'History';
  String get tabFavorites => _zh ? '收藏' : 'Favorites';
  String get clearAll => _zh ? '清空' : 'Clear all';
  String get gridView => _zh ? '网格视图' : 'Grid view';
  String get listView => _zh ? '列表视图' : 'List view';
  String get noGalleriesFound => _zh ? '没有找到画廊' : 'No galleries found';
  String get loadFailedTapRetry => _zh ? '加载失败，点击重试' : 'Load failed, tap to retry';
  String get loginToFavorite => _zh ? '登录以收藏！' : 'Login to favorite!';

  // ---- Home Drawer ----
  String get home => _zh ? '首页' : 'Home';
  String get favorites => _zh ? '收藏' : 'Favorites';
  String get history => _zh ? '历史' : 'History';
  String get downloads => _zh ? '下载' : 'Downloads';
  String get settings => _zh ? '设置' : 'Settings';

  // ---- Home History Tab ----
  String get loadingHistory => _zh ? '正在读取历史记录…' : 'Loading history…';
  String get noHistoryRecords => _zh ? '暂无浏览记录' : 'No reading history';
  String get historyHint => _zh ? '浏览过的画廊将出现在此处' : 'Galleries you visit will appear here';
  String get clearHistory => _zh ? '清空浏览记录' : 'Clear History';
  String get clearHistoryConfirm => _zh ? '确定要清空所有浏览记录吗？' : 'Are you sure you want to clear all reading history?';
  String get clearAllButton => _zh ? '清空' : 'Clear All';
  String get justNow => _zh ? '刚刚' : 'Just now';
  String minutesAgo(int n) => _zh ? '$n分钟前' : '${n}m ago';
  String hoursAgo(int n) => _zh ? '$n小时前' : '${n}h ago';
  String daysAgo(int n) => _zh ? '$n天前' : '${n}d ago';

  // ---- Settings Screen ----
  String get checkUpdate => _zh ? '检查更新' : 'Check for updates';
  String get checkingUpdate => _zh ? '正在检查更新…' : 'Checking for updates…';
  String get checkUpdateHint => _zh ? '检查最新正式版本' : 'Check for the latest release';
  String get updateAvailable => _zh ? '已有新版本' : 'Update available';
  String updateInstallPrompt(String version) => _zh ? '最新版本为 $version，点击安装' : 'The latest version is $version. Click to install.';
  String get updateStorageFailed => _zh ? '无法保存更新提示，请重试' : 'Could not save the update reminder. Please retry';
  String get versionCurrent => _zh ? '当前已是最新版本' : 'You are on the latest version';
  String get versionAhead => _zh ? '当前版本高于最新正式版' : 'Your version is newer than the latest release';
  String get noReleaseAvailable => _zh ? '暂无可用正式版本' : 'No release is available yet';
  String get updateNetworkFailed => _zh ? '检查更新失败，请检查网络后重试' : 'Could not check for updates. Check your connection and retry';
  String get updateTimedOut => _zh ? '检查更新超时，请重试' : 'Update check timed out. Please retry';
  String get updateRateLimited => _zh ? '检查更新请求受限，请稍后重试' : 'Update checks are rate limited. Please try again later';
  String get updateInvalidResponse => _zh ? '无法读取发布版本信息，请稍后重试' : 'Could not read release information. Please try again later';
  String get releaseOpenFailed => _zh ? '无法打开浏览器，请重试' : 'Could not open the browser. Please retry';
  String get reopenRelease => _zh ? '重新打开' : 'Open again';
  String get versionUnavailable => _zh ? '版本信息不可用' : 'Version information unavailable';
  String get appearance => _zh ? '外观' : 'Appearance';
  String get theme => _zh ? '主题' : 'Theme';
  String get followSystem => _zh ? '跟随系统' : 'Follow system';
  String get light => _zh ? '浅色' : 'Light';
  String get dark => _zh ? '深色' : 'Dark';
  String get galleryDisplay => _zh ? '画廊显示' : 'Gallery Display';
  String get language => _zh ? '语言' : 'Language';

  String get site => _zh ? '站点' : 'Site';
  String get myTags => _zh ? '我的标签' : 'My Tags';
  String get configureTagFilters => _zh ? '配置标签过滤' : 'Configure tag filters';
  String hiddenTagsCount(int n) => _zh ? '$n 个隐藏标签' : '$n hidden tag(s)';
  String get titleLanguage => _zh ? '标题语言' : 'Title Language';
  String get titleLanguageHint => _zh ? '在网页设置中更改标题显示语言' : 'Change title display language in site settings';
  String get imageSizeSettings => _zh ? '图片尺寸设置' : 'Image Size Settings';
  String get imageSizeSettingsHint => _zh ? '在网页设置中更改图片分辨率限制' : 'Change image resolution limit in site settings';

  String get reading => _zh ? '阅读' : 'Reading';
  String get defaultReadingMode => _zh ? '默认阅读模式' : 'Default Reading Mode';
  String get leftToRight => _zh ? '从左到右' : 'Left to Right';
  String get rightToLeft => _zh ? '从右到左' : 'Right to Left';
  String get verticalScroll => _zh ? '垂直滚动' : 'Vertical Scroll';

  String get network => _zh ? '网络' : 'Network';
  String get autoDetectProxy => _zh ? '自动检测代理' : 'Auto Detect Proxy';
  String autoProxyDetected(String proxy) => _zh ? '自动: $proxy' : 'Auto: $proxy';
  String get vpnDetectedNoProxy => _zh ? 'VPN已检测到，未找到本地代理' : 'VPN detected, no local proxy found';
  String get noProxyVpnDetected => _zh ? '未检测到代理/VPN' : 'No proxy/VPN detected';
  String get disabled => _zh ? '已禁用' : 'Disabled';
  String get manualProxy => _zh ? '手动代理' : 'Manual Proxy';
  String get notConfigured => _zh ? '未配置' : 'Not configured';
  String activeProxy(String proxy) => _zh ? '当前代理: $proxy' : 'Active proxy: $proxy';
  String get vpnModeNoProxy => _zh ? 'VPN模式，无需代理' : 'VPN mode, no proxy needed';
  String get noProxyActive => _zh ? '无活动代理' : 'No proxy active';
  String get httpProxy => _zh ? 'HTTP 代理' : 'HTTP Proxy';
  String get enterProxyUrl => _zh ? '输入代理URL用于网络访问' : 'Enter proxy URL for network access';
  String get supportsHttpSocks5 => _zh ? '支持HTTP和SOCKS5' : 'Supports HTTP and SOCKS5';

  String get storage => _zh ? '存储' : 'Storage';
  String get imageCache => _zh ? '图片缓存' : 'Image Cache';
  String get tapToClear => _zh ? '点击清除' : 'Tap to clear';
  String get cacheCleared => _zh ? '缓存已清除' : 'Cache cleared';
  String get clearingCache => _zh ? '正在清除图片缓存…' : 'Clearing image cache…';
  String get calculatingCacheSize => _zh ? '正在统计…' : 'Calculating…';
  String get cacheSizeUnavailable => _zh ? '暂时无法统计缓存大小' : 'Cache size unavailable';
  String get cacheClearFailed => _zh ? '图片缓存未能全部清除，请重试' : 'Some image cache could not be cleared. Please retry.';
  String get cacheSizeLimit => _zh ? '缓存大小限制' : 'Cache Size Limit';
  String get downloadsStorage => _zh ? '下载' : 'Downloads';

  String get about => _zh ? '关于' : 'About';
  String get appDescription => _zh ? 'Flutter漫画阅读器 for E-Hentai\nfyaaa142857' : 'Flutter manga reader for E-Hentai\nfyaaa142857';

  String get exhentaiRequiresIgneous => _zh ? 'exhentai.org (需要igneous cookie)' : 'exhentai.org (requires igneous cookie)';

  // ---- Search Screen ----
  String get searchGalleries => _zh
      ? '输入标题、作者、Tag、画廊gid、上传者...'
      : 'Enter title, author, Tag, gallery GID, uploader...';
  String get noResultsFound => _zh ? '没有搜索结果' : 'No results found';
  String get tryDifferentKeywords => _zh ? '试试不同的关键词或过滤器' : 'Try different keywords or filters';
  String get enterKeywordToSearch => _zh ? '输入关键词搜索' : 'Enter a keyword to search';
  String get recentSearches => _zh ? '最近搜索' : 'Recent Searches';
  String get searchFilters => _zh ? '搜索过滤' : 'Search Filters';
  String get categories => _zh ? '分类' : 'Categories';
  String get minimumRating => _zh ? '最低评分' : 'Minimum Rating';
  String get any => _zh ? '任意' : 'Any';
  String get applyFilters => _zh ? '应用过滤' : 'Apply Filters';

  // ---- Login Screen ----
  String get account => _zh ? '账户' : 'Account';
  String get loggedIn => _zh ? '已登录' : 'Logged in';
  String memberId(String id) => _zh ? '会员ID: $id' : 'Member ID: $id';
  String get logoutConfirm => _zh ? '确定要退出登录吗？' : 'Are you sure you want to logout?';
  String get loginSuccessful => _zh ? '登录成功！' : 'Login successful!';
  String get loginFailed => _zh ? '登录失败' : 'Login failed';
  String get webViewLogin => _zh ? 'WebView 登录' : 'WebView Login';
  String get manualCookie => _zh ? '手动 Cookie' : 'Manual Cookie';
  String get howToGetCookies => _zh ? '如何获取Cookies' : 'How to get cookies';
  String get cookieInstructions => _zh
      ? '1. 在浏览器中登录 e-hentai.org\n'
        '2. 打开开发者工具 (F12)\n'
        '3. 进入 Application > Cookies\n'
        '4. 复制下方的值'
      : '1. Log in to e-hentai.org in your browser\n'
        '2. Open Developer Tools (F12)\n'
        '3. Go to Application > Cookies\n'
        '4. Copy the values below';
  String get igneousOptional => _zh ? 'igneous (可选，用于ExHentai)' : 'igneous (optional, for ExHentai)';
  String get memberIdPassHashRequired => _zh ? 'Member ID 和 Pass Hash 为必填' : 'Member ID and Pass Hash are required';

  // ---- Gallery Detail Screen ----
  String get galleryContentWarning => _zh ? '站点内容提示' : 'Site content warning';
  String get galleryWarningExplanation => _zh ? '站点对该画廊显示了内容提示。继续后将记住该画廊的确认状态，重启应用后无需再次确认；删除该画廊的浏览记录时会同时清除确认状态。' : 'The site has flagged this gallery. Your confirmation will be remembered across app restarts until you delete this gallery from browsing history.';
  String get continueGallery => _zh ? '继续查看' : 'Continue to gallery';
  String get loadingDetails => _zh ? '正在加载详情...' : 'Loading details...';
  String get failedToLoad => _zh ? '加载失败' : 'Failed to load';
  String get uploader => _zh ? '上传者' : 'Uploader';
  String get languageLabel => _zh ? '语言' : 'Language';
  String get pages => _zh ? '页数' : 'Pages';
  String pagesCount(int n) => _zh ? '$n 页' : '$n pages';
  String get posted => _zh ? '发布时间' : 'Posted';
  String get size => _zh ? '大小' : 'Size';
  String get read => _zh ? '阅读' : 'Read';
  String readProgress(int current, int total) => 'P.$current / $total';
  String get tags => _zh ? '标签' : 'Tags';
  String get preview => _zh ? '预览' : 'Preview';
  String get similarGalleries => _zh ? '相似画廊' : 'Similar Galleries';
  String comments(int n) => _zh ? '评论 ($n)' : 'Comments ($n)';
  String viewAllComments(int n) => _zh ? '查看全部 $n 条评论' : 'View all $n comments';
  String moreComments(int n) => _zh ? '还有 $n 条评论低于显示阈值，继续加载' :
      'There are $n more comments below the viewing threshold';
  String get writeComment => _zh ? '发表评论' : 'Write a comment';
  String get sendComment => _zh ? '发送' : 'Send';
  String get commentHint => _zh ? '输入评论内容' : 'Enter your comment';
  String get loginToComment => _zh ? '请先登录后评论或投票' : 'Log in to comment or vote';
  String get unknownCommentTime => _zh ? '时间未知' : 'Unknown time';
  String get upvoteComment => _zh ? '点赞' : 'Upvote';
  String get downvoteComment => _zh ? '点踩' : 'Downvote';
  String get noComments => _zh ? '暂无评论' : 'No comments yet';
  String get uploaderBadge => _zh ? '上传者' : 'Uploader';
  String get startDownloadConfirm => _zh ? '开始下载？' : 'Start to Download?';
  String get downloadStarted => _zh ? '下载已开始' : 'Download started';
  String get rateGallery => _zh ? '为画廊评分' : 'Rate Gallery';
  String rated(String rating) => _zh ? '已评分 $rating' : 'Rated $rating';

  // ---- Favorites Screen ----
  String get noCloudFavorites => _zh ? '没有云端收藏' : 'No cloud favorites';
  String get saveFromDetail => _zh ? '从详情页保存画廊' : 'Save galleries from the detail page';

  // ---- History Screen ----
  String get noReadingHistory => _zh ? '暂无浏览记录' : 'No reading history';
  String get galleriesWillAppear => _zh ? '浏览过的画廊将出现在此处' : 'Galleries you visit will appear here';

  // ---- Download Screen ----
  String get noDownloads => _zh ? '没有下载' : 'No downloads';
  String get downloadFromDetail => _zh ? '从详情页下载画廊' : 'Download galleries from the detail page';
  String downloading(int percent) => _zh ? '下载中... $percent%' : 'Downloading... $percent%';
  String get paused => _zh ? '已暂停' : 'Paused';
  String get completed => _zh ? '已完成' : 'Completed';
  String get failedTapRetry => _zh ? '失败 - 点击重试' : 'Failed - Tap to retry';
  String get pending => _zh ? '等待中' : 'Pending';

  // ---- Thumbnail Preview Screen ----
  String get loadingThumbnails => _zh ? '正在加载缩略图...' : 'Loading thumbnails...';
  String get failedToLoadThumbnails => _zh ? '加载缩略图失败' : 'Failed to load thumbnails';

  // ---- Reader Screen ----
  String readerPageTitle(int page) => _zh ? '第 $page 页' : 'Page $page';
  String get reloadPage => _zh ? '重新加载' : 'Reload';
  String get savePage => _zh ? '保存' : 'Save';
  String get savingPage => _zh ? '正在保存…' : 'Saving…';
  String get pageSaved => _zh ? '已保存到相册' : 'Saved to Photos';
  String get pageSavedAsPng => _zh ? '已转换为 PNG 静态图并保存到相册' : 'Converted to a static PNG and saved to Photos';
  String get photoPermissionDenied => _zh ? '请在系统设置中允许保存照片' : 'Allow saving photos in system settings';
  String get pageResourceUnavailable => _zh ? '图片资源已不可用，请重新加载该页面' : 'Image resource unavailable. Reload this page.';
  String get pageSaveFailed => _zh ? '保存失败，请重试' : 'Could not save image. Please try again.';
  String get loadingReader => _zh ? '正在加载阅读器...' : 'Loading reader...';
  String get failedToLoadReader => _zh ? '加载阅读器失败' : 'Failed to load reader';
  String get noPagesAvailable => _zh ? '没有可用页面' : 'No pages available';
  String get readingMode => _zh ? '阅读模式' : 'Reading mode';

  // ---- Error Widget ----
  String get proxyHint => _zh ? 'E-Hentai可能需要代理才能访问。\n前往设置进行配置。' : 'E-Hentai may require a proxy to access.\nGo to Settings to configure.';
  String get proxy => _zh ? '代理' : 'Proxy';

  // ---- Loading Indicator ----
  String get calculating => _zh ? '计算中...' : 'Calculating...';
}
