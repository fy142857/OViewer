import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:oviewer/models/reader_page_layout.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/repositories/settings_repository.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_event.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final total in [0, 1, 2, 3, 8, 9]) {
    for (final layout in ReaderPageLayout.values) {
      test('$total pages in $layout retain original indices and last page', () {
        final spreads = ReaderSpreads(total, layout);
        final pages = [
          for (var i = 0; i < spreads.count; i++) ...spreads.pages(i)
        ];
        expect(pages, List.generate(total, (i) => i));
        for (var page = 0; page < total; page++) {
          final group = spreads.containing(page);
          expect(group, contains(page));
          expect(spreads.pages(spreads.spreadOf(page), reverse: true),
              group.reversed.toList());
        }
        if (total.isOdd && layout == ReaderPageLayout.doublePage) {
          expect(spreads.pages(spreads.count - 1), [total - 1]);
          expect(spreads.label(total - 1), '$total');
        }
      });
    }
  }
  test('range label stays in original ascending page numbers', () {
    expect(const ReaderSpreads(5, ReaderPageLayout.doublePage).label(1), '1–2');
    expect(const ReaderSpreads(5, ReaderPageLayout.doublePage).label(3), '3–4');
  });
  for (final saved in [null, 'unknown', 123, 'single', 'doublePage']) {
    test(
        'saved layout $saved restores safely without changing reading direction',
        () async {
      SharedPreferences.setMockInitialValues(
          {'reading_mode': 1, if (saved != null) 'reader_page_layout': saved});
      final storage = LocalStorage();
      await storage.init();
      final repo = SettingsRepository(storage);
      expect(
          repo.getReaderPageLayout(),
          saved == 'doublePage'
              ? ReaderPageLayout.doublePage
              : ReaderPageLayout.single);
      final bloc =
          SettingsBloc(repo, initialState: SettingsBloc.readSaved(repo));
      bloc.add(const UpdateReaderPageLayout(ReaderPageLayout.doublePage));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.pageLayout, ReaderPageLayout.doublePage);
      expect(bloc.state.readingMode, 1);
      final reopened = LocalStorage();
      await reopened.init();
      expect(SettingsBloc.readSaved(SettingsRepository(reopened)).pageLayout,
          ReaderPageLayout.doublePage);
      await bloc.close();
    });
  }
}
