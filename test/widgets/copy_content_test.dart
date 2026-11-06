import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/gallery_detail/gallery_detail_bloc.dart';
import 'package:oviewer/blocs/gallery_detail/gallery_detail_state.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/models/gallery_comment.dart';
import 'package:oviewer/models/gallery_tag.dart';
import 'package:oviewer/widgets/comment_card.dart';
import 'package:oviewer/widgets/tag_chip.dart';

class _Detail extends Mock implements GalleryDetailBloc {}

class _Settings extends Mock implements SettingsBloc {}

void main() {
  for (final dispose in [false, true]) {
    testWidgets(
        'copy confirmation waits for clipboard success and mounted context dispose=$dispose',
        (tester) async {
      final settings = _Settings();
      when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
      when(() => settings.stream).thenAnswer((_) => const Stream.empty());
      final copied = Completer<void>();
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') await copied.future;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settings,
          child: const MaterialApp(
              home: Scaffold(
                  body: TagChip(
                      tag: GalleryTag(namespace: 'artist', key: 'Example'))))));
      await tester.longPress(find.text('Example'));
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
      if (dispose) await tester.pumpWidget(const SizedBox());
      copied.complete();
      await tester.pumpAndSettle();
      expect(find.text('Copied'), dispose ? findsNothing : findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'translated tag long press copies original and shows bottom confirmation; tap still searches',
      (tester) async {
    final copied = <String>[];
    var taps = 0;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData')
        copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    final settings = _Settings();
    when(() => settings.state).thenReturn(const SettingsState(locale: 'zh'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
        value: settings,
        child: MaterialApp(
            home: Scaffold(
                body: TagChip(
                    tag: const GalleryTag(
                        namespace: 'female',
                        key: 'full color',
                        translation: '中文标签'),
                    onTap: () => taps++)))));
    await tester.longPress(find.text('中文标签'));
    await tester.pumpAndSettle();
    expect(copied, ['female:full color']);
    expect(taps, 0);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('已复制'), findsOneWidget);
    expect(tester.getBottomLeft(find.byType(SnackBar)).dy, 600);
    expect(find.text('female:full color'), findsNothing);
    await tester.tap(find.text('中文标签'));
    expect(taps, 1);
  });
  testWidgets(
      'comment rich text can be selected and copied without losing gallery links',
      (tester) async {
    final detail = _Detail();
    final settings = _Settings();
    when(() => detail.state).thenReturn(const GalleryDetailState());
    when(() => detail.stream).thenAnswer((_) => const Stream.empty());
    when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
    when(() => settings.stream).thenAnswer((_) => const Stream.empty());
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData')
        copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MultiBlocProvider(
        providers: [
          BlocProvider<GalleryDetailBloc>.value(value: detail),
          BlocProvider<SettingsBloc>.value(value: settings)
        ],
        child: MaterialApp(
            home: Scaffold(
                body: CommentCard(
                    gid: 1,
                    token: 'abc',
                    comment: GalleryComment(
                        id: 0,
                        author: 'uploader',
                        content: 'Hello<br>https://e-hentai.org/g/42/abc/',
                        postedAt: DateTime(2026),
                        isUploader: true))))));
    final selectable =
        tester.widget<SelectableText>(find.byType(SelectableText));
    expect(selectable.textSpan!.toPlainText(),
        'Hello\nhttps://e-hentai.org/g/42/abc/');
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    editable.selectAll(SelectionChangedCause.toolbar);
    editable.copySelection(SelectionChangedCause.toolbar);
    await tester.pumpAndSettle();
    expect(copied, 'Hello\nhttps://e-hentai.org/g/42/abc/');
    final span = selectable.textSpan!.children!.whereType<TextSpan>().last;
    expect(span.recognizer, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
