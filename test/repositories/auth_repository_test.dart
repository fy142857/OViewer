import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/repositories/auth_repository.dart';

void main() {
  group('AuthRepository.isLoginPageHtml', () {
    test('detects the E-Hentai login title', () {
      expect(
        AuthRepository.isLoginPageHtml(
          '<html><title>E-Hentai.org Login</title></html>',
        ),
        isTrue,
      );
    });

    test('detects a forums login form', () {
      expect(
        AuthRepository.isLoginPageHtml(
          '<form action="https://forums.e-hentai.org/index.php?act=Login">',
        ),
        isTrue,
      );
    });

    test('accepts a user configuration page', () {
      expect(
        AuthRepository.isLoginPageHtml(
          '<html><title>E-Hentai Galleries</title><form action="uconfig.php">',
        ),
        isFalse,
      );
    });
  });
}
