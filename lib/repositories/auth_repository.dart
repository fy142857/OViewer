import '../core/network/dio_client.dart';
import '../core/network/cookie_manager.dart';
import '../core/constants/api_endpoints.dart';
import '../models/user_profile.dart';

class AuthRepository {
  final DioClient _dio;
  final CookieManager _cookieManager;

  AuthRepository(this._dio, this._cookieManager);

  /// Check if user is logged in
  Future<bool> isLoggedIn() => _cookieManager.hasLoginCookies();

  /// Save login cookies (from WebView or manual input)
  Future<void> saveLoginCookies({
    required String memberId,
    required String passHash,
    String? igneous,
  }) async {
    await _cookieManager.saveLoginCookies(
      memberId: memberId,
      passHash: passHash,
      igneous: igneous,
    );
  }

  /// Validate that current cookies produce a logged-in session
  Future<bool> validateLogin() async {
    try {
      final html = await _dio.get(ApiEndpoints.userConfig);
      return !isLoginPageHtml(html);
    } catch (_) {
      return false;
    }
  }

  static bool isLoginPageHtml(String html) {
    return RegExp(
          r'<title>\s*E-Hentai\.org Login\s*</title>',
          caseSensitive: false,
        ).hasMatch(html) ||
        RegExp(
          r'''<form[^>]+action=["'][^"']*act=Login''',
          caseSensitive: false,
        ).hasMatch(html);
  }

  /// Get user profile info
  Future<UserProfile> getUserProfile() async {
    final memberId = await _cookieManager.getMemberId();
    if (memberId == null) return const UserProfile.guest();

    return UserProfile(
      memberId: memberId,
      isLoggedIn: true,
    );
  }

  /// Logout - clear all cookies
  Future<void> logout() async {
    await _cookieManager.clearCookies();
  }

  /// Get login page URL for WebView
  String get loginPageUrl => ApiEndpoints.loginPage;
}
