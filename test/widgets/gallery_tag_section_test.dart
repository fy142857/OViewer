import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/core/utils/uploader_search_query.dart';
import 'package:oviewer/models/gallery_tag.dart';
import 'package:oviewer/widgets/gallery_tag_section.dart';
import 'package:oviewer/widgets/tag_chip.dart';

class Settings extends Mock implements SettingsBloc {}

Widget withSettings(Widget child) {
  final settings = Settings();
  when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
  when(() => settings.stream).thenAnswer((_) => const Stream.empty());
  return BlocProvider<SettingsBloc>.value(value: settings, child: child);
}

void main() {
  test(
      'uploader qualifier preserves complete names, without tag suffixes or aliases',
      () {
    for (final name in [
      'Name With Spaces',
      '中文上传者',
      '12345',
      'Name | Alias',
      'A&B+/#'
    ]) {
      expect(uploaderSearchQuery(' $name '), 'uploader:"$name"');
    }
    for (final name in ['', '  ', 'Unknown', 'a" -uploader:b', 'a\nb']) {
      expect(uploaderSearchQuery(name), isNull);
    }
  });

  for (final locale in ['zh', 'en']) {
    testWidgets(
        'uploader follows other, remains literal and sends its search ($locale)',
        (tester) async {
      final settings = Settings();
      when(() => settings.state).thenReturn(SettingsState(locale: locale));
      when(() => settings.stream).thenAnswer((_) => const Stream.empty());
      final queries = <String>[];
      const tags = [
        GalleryTag(namespace: 'other', key: 'full color'),
        GalleryTag(namespace: 'artist', key: 'Name | Alias')
      ];
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settings,
          child: MaterialApp(
              home: Scaffold(
                  body: SizedBox(
                      width: 320,
                      child: GalleryTagSection(
                          tags: tags,
                          uploader: '上传者 Name | Alias',
                          onSearch: queries.add))))));
      expect(tester.getTopLeft(find.text('uploader:')).dy,
          greaterThan(tester.getTopLeft(find.text('other:')).dy));
      expect(tester.getTopLeft(find.text('uploader:')).dy,
          lessThan(tester.getTopLeft(find.text('artist:')).dy));
      expect(tester.getTopLeft(find.text('uploader:')).dx,
          tester.getTopLeft(find.text('other:')).dx);
      final chip = tester
          .widgetList<TagChip>(find.byType(TagChip))
          .singleWhere((chip) => chip.tag.namespace == 'uploader');
      expect(chip.showTranslation, false);
      await tester.tap(find.text('上传者 Name | Alias'));
      expect(queries, ['uploader:"上传者 Name | Alias"']);
      await tester.tap(find.text('Name | Alias'));
      expect(queries.last, r'artist:"Name$"');
      expect(tags.length, 2);
      expect(tester.takeException(), isNull);
    });
  }

  for (final tags in [
    <GalleryTag>[],
    [const GalleryTag(namespace: 'artist', key: 'Artist')]
  ]) {
    testWidgets('uploader is available without other (tags=${tags.length})',
        (tester) async {
      final queries = <String>[];
      await tester.pumpWidget(MaterialApp(
          builder: (_, child) => withSettings(child!),
          home: Scaffold(
              body: GalleryTagSection(
                  tags: tags, uploader: 'Account', onSearch: queries.add))));
      expect(find.text('uploader:'), findsOneWidget);
      expect(find.text('other:'), findsNothing);
      await tester.tap(find.text('Account'));
      expect(queries.single, 'uploader:"Account"');
    });
  }

  testWidgets('missing name does not create an empty search entry',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        builder: (_, child) => withSettings(child!),
        home: GalleryTagSection(
            tags: const [],
            uploader: ' ',
            onSearch: (_) => fail('Unexpected search'))));
    expect(find.byType(TagChip), findsNothing);
  });
}
