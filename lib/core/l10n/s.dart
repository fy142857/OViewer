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

  // ---- Common ----
  String get cancel => _zh ? '取消' : 'Cancel';
  String get confirm => _zh ? '确认' : 'Confirm';
  String get save => _zh ? '保存' : 'Save';
  String get clear => _zh ? '清除' : 'Clear';
  String get delete => _zh ? '删除' : 'Delete';
  String get retry => _zh ? '重试' : 'Retry';
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
  String get cacheSizeLimit => _zh ? '缓存大小限制' : 'Cache Size Limit';
  String get downloadsStorage => _zh ? '下载' : 'Downloads';

  String get about => _zh ? '关于' : 'About';
  String get appDescription => _zh ? 'Flutter漫画阅读器 for E-Hentai\nfyaaa142857' : 'Flutter manga reader for E-Hentai\nfyaaa142857';

  String get exhentaiRequiresIgneous => _zh ? 'exhentai.org (需要igneous cookie)' : 'exhentai.org (requires igneous cookie)';

  // ---- Search Screen ----
  String get searchGalleries => _zh ? '搜索画廊...' : 'Search galleries...';
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
