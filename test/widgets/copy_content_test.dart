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
  testWidgets(
      'translated tag long press copies original qualified tag silently; tap still searches',
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
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: TagChip(
                tag: const GalleryTag(
                    namespace: 'female',
                    key: 'full color',
                    translation: '中文标签'),
                onTap: () => taps++))));
    await tester.longPress(find.text('中文标签'));
    await tester.pumpAndSettle();
    expect(copied, ['female:full color']);
    expect(taps, 0);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
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
