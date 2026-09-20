import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/core/constants/api_endpoints.dart';
import 'package:oviewer/core/constants/app_constants.dart';

void main() {
  late bool originalSite;

  setUp(() => originalSite = AppConstants.useExHentai);
  tearDown(() => AppConstants.useExHentai = originalSite);

  test('settings endpoints follow EH, EX, and switching back to EH', () {
    for (final useEx in [false, true, false]) {
      AppConstants.useExHentai = useEx;
      final host = useEx ? 'exhentai.org' : 'e-hentai.org';

      expect(ApiEndpoints.userConfig, 'https://$host/uconfig.php');
      expect(ApiEndpoints.myTags, 'https://$host/mytags');
    }
  });
}
