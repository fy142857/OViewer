import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oviewer/features/uploads/data/upload_protocol.dart';
import 'package:oviewer/features/uploads/presentation/upload_editor_form.dart';

UploadEditorSnapshot newSnapshot() => const UploadProtocol().editor(
      File('test/fixtures/uploads/new.html').readAsStringSync(),
      Uri.parse('https://upld.e-hentai.org/managegallery?act=new'),
    );

UploadEditorSnapshot revise(
  UploadEditorSnapshot source, {
  Map<String, UploadField>? fields,
  Map<String, UploadButton>? buttons,
  Map<String, String>? metadata,
  Uri? uri,
}) =>
    UploadEditorSnapshot(
      uri: uri ?? source.uri,
      form: UploadForm(
        action: source.form.action,
        fields: fields ?? source.form.fields,
        multipart: source.form.multipart,
      ),
      api: source.api,
      buttons: buttons ?? source.buttons,
      images: source.images,
      metadata: metadata ?? source.metadata,
      links: source.links,
      reorderForm: source.reorderForm,
    );

UploadField fieldValue(UploadField field, List<String> values,
        {bool? readOnly, bool? disabled, List<UploadOption>? options}) =>
    UploadField(
      name: field.name,
      type: field.type,
      values: values,
      options: options ?? field.options,
      disabled: disabled ?? field.disabled,
      readOnly: readOnly ?? field.readOnly,
      maxLength: field.maxLength,
    );

const completeDraft = <String, List<String>>{
  'gname_en': ['Example work'],
  'category': ['9'],
  'langtag': ['1058'],
  'langtype': ['0'],
  'tos': ['on'],
};

Widget host(Widget child, {String language = 'en', double scale = 1}) =>
    MaterialApp(
      locale: Locale(language),
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(builder: (context) {
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(padding: const EdgeInsets.all(12), child: child),
            ),
          ),
        );
      }),
    );

Finder control(String name) => find.byKey(ValueKey('upload-field-$name'));
Finder action(String name) =>
    find.byKey(ValueKey('upload-action-${name}button'));

Future<void> enter(WidgetTester tester, String name, String text) async {
  await tester.ensureVisible(control(name));
  await tester.enterText(control(name), text);
  await tester.pump();
}

Future<void> tapControl(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> select(WidgetTester tester, String name, String label) async {
  await tapControl(tester, control(name));
  final option = find.text(label).last;
  await tester.ensureVisible(option);
  await tester.tap(option);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'new form requires explicit choices and does not expose hidden fields',
      (tester) async {
    Map<String, List<String>>? edits;
    await tester.pumpWidget(host(UploadEditorForm(
      snapshot: newSnapshot(),
      onChanged: (values) => edits = values,
      onSave: () {},
      onUpload: () {},
      onPublish: () {},
      onOpenSource: (_) {},
    )));
    await tester.pump();
    expect(edits!['category'], isEmpty);
    expect(edits!['langtag'], isEmpty);
    expect(edits!['langtype'], isEmpty);
    expect(edits!['tos'], isEmpty);
    expect(edits!.keys, isNot(contains('PHP_SESSION_UPLOAD_PROGRESS')));
    expect(edits!.keys, isNot(contains('do_save')));
    expect(edits!.keys, isNot(contains('MAX_FILE_SIZE')));
    expect(edits!.keys, isNot(contains('files[]')));
    expect(find.textContaining('fixture-progress'), findsNothing);
    expect(find.textContaining('fixture-api-key'), findsNothing);
    expect(tester.widget<FilledButton>(action('save')).onPressed, isNull);
    expect(tester.widget<FilledButton>(action('upload')).onPressed, isNull);
    expect(tester.widget<FilledButton>(action('publish')).onPressed, isNull);
  });

  testWidgets(
      'explicit input enables save/upload but never an empty-gallery publish',
      (tester) async {
    Map<String, List<String>>? edits;
    var saves = 0;
    await tester.pumpWidget(host(UploadEditorForm(
      snapshot: newSnapshot(),
      onChanged: (values) => edits = values,
      onSave: () => saves++,
      onUpload: () {},
      onPublish: () {},
      onOpenSource: (_) {},
    )));
    await enter(tester, 'gname_en', 'Actual title');
    await select(tester, 'category', 'Non-H');
    await select(tester, 'langtag', 'English');
    await tapControl(tester, find.byKey(const ValueKey('upload-langtype-0')));
    expect(tester.widget<FilledButton>(action('save')).onPressed, isNull);
    await tapControl(tester, control('tos'));
    expect(edits!['category'], ['9']);
    expect(edits!['langtag'], ['1058']);
    expect(edits!['langtype'], ['0']);
    expect(edits!['tos'], ['on']);
    expect(tester.widget<FilledButton>(action('save')).onPressed, isNotNull);
    expect(tester.widget<FilledButton>(action('upload')).onPressed, isNotNull);
    expect(tester.widget<FilledButton>(action('publish')).onPressed, isNull);
    await tapControl(tester, action('save'));
    expect(saves, 1);
    expect(edits!['gname_en'], ['Actual title']);
    expect(() => edits!['gname_en']!.add('mutation'), throwsUnsupportedError);
  });

  testWidgets(
      'restoring a local draft restores explicit options without inventing fields',
      (tester) async {
    Map<String, List<String>>? edits;
    await tester.pumpWidget(host(UploadEditorForm(
      snapshot: newSnapshot(),
      initialValues: const {
        ...completeDraft,
        'PHP_SESSION_UPLOAD_PROGRESS': ['not-an-edit'],
        'unknown_secret': ['not-an-edit'],
      },
      onChanged: (values) => edits = values,
      onSave: () {},
      onOpenSource: (_) {},
    )));
    await tester.pump();
    expect(tester.widget<TextField>(control('gname_en')).controller!.text,
        'Example work');
    expect(edits!['category'], ['9']);
    expect(edits!['tos'], ['on']);
    expect(edits!.keys, isNot(contains('unknown_secret')));
    expect(tester.widget<FilledButton>(action('save')).onPressed, isNotNull);
  });

  testWidgets(
      'human translator declaration is cleared when changing to Rewrite',
      (tester) async {
    Map<String, List<String>>? edits;
    await tester.pumpWidget(host(UploadEditorForm(
      snapshot: newSnapshot(),
      initialValues: completeDraft,
      onChanged: (values) => edits = values,
      onSave: () {},
      onOpenSource: (_) {},
    )));
    expect(control('langctl'), findsNothing);
    await tapControl(tester, find.byKey(const ValueKey('upload-langtype-1')));
    await tapControl(tester, control('langctl'));
    expect(edits!['langtype'], ['1']);
    expect(edits!['langctl'], ['on']);
    await tapControl(tester, find.byKey(const ValueKey('upload-langtype-2')));
    expect(edits!['langtype'], ['2']);
    expect(edits!['langctl'], isEmpty);
    expect(control('langctl'), findsNothing);
    await tapControl(tester, find.byKey(const ValueKey('upload-langtype-1')));
    expect(tester.widget<CheckboxListTile>(control('langctl')).value, isFalse);
  });

  testWidgets(
      'AI checkbox follows website title indicator behavior and previews result',
      (tester) async {
    Map<String, List<String>>? edits;
    await tester.pumpWidget(host(UploadEditorForm(
      snapshot: newSnapshot(),
      initialValues: completeDraft,
      onChanged: (values) => edits = values,
      onOpenSource: (_) {},
    )));
    await enter(tester, 'gname_en', '  Work [AI-Generated] AIgenerated  ');
    await tapControl(tester, control('aigen'));
    expect(edits!['aigen'], ['on']);
    expect(edits!['gname_en'], ['Work [AI Generated]']);
    expect(find.text('Title preview: Work [AI Generated]'), findsOneWidget);
    await tapControl(tester, control('aigen'));
    expect(edits!['aigen'], isEmpty);
    expect(edits!['gname_en'], ['Work']);
  });

  testWidgets(
      'server readonly values remain visible and are excluded from edits',
      (tester) async {
    final source = newSnapshot();
    final fields = {
      ...source.form.fields,
      'gname_en': fieldValue(source.form.fields['gname_en']!, ['Locked title'],
          readOnly: true),
      'category':
          fieldValue(source.form.fields['category']!, ['9'], disabled: true),
    };
    Map<String, List<String>>? edits;
    await tester.pumpWidget(host(UploadEditorForm(
      snapshot: revise(source,
          fields: fields,
          uri: Uri.parse('https://upld.e-hentai.org/managegallery?ulgid=123')),
      onChanged: (values) => edits = values,
      onOpenSource: (_) {},
    )));
    await tester.pump();
    expect(tester.widget<TextField>(control('gname_en')).readOnly, isTrue);
    expect(tester.widget<TextField>(control('gname_en')).controller!.text,
        'Locked title');
    expect(find.byKey(const ValueKey('upload-field-restriction-gname_en')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('upload-field-restriction-category')),
        findsOneWidget);
    expect(tester.widget<CheckboxListTile>(control('aigen')).onChanged, isNull);
    expect(edits!.keys, isNot(contains('gname_en')));
    expect(edits!.keys, isNot(contains('category')));
  });

  testWidgets(
      'restoring identical readonly fields does not create a false conflict',
      (tester) async {
    final source = newSnapshot();
    await tester.pumpWidget(host(UploadEditorForm(
      snapshot: revise(source, fields: {
        ...source.form.fields,
        'gname_en': fieldValue(
            source.form.fields['gname_en']!, ['Example work'],
            readOnly: true),
      }),
      initialValues: completeDraft,
      onChanged: (_) {},
      onSave: () {},
      onOpenSource: (_) {},
    )));
    expect(find.byKey(const ValueKey('upload-editor-conflict')), findsNothing);
    expect(tester.widget<FilledButton>(action('save')).onPressed, isNotNull);
    expect(tester.widget<TextField>(control('gname_en')).controller!.text,
        'Example work');
  });

  testWidgets(
      'same-gallery refresh preserves dirty input and updates untouched fields',
      (tester) async {
    final source = newSnapshot();
    Map<String, List<String>>? edits;
    Widget editor(UploadEditorSnapshot snapshot) => host(UploadEditorForm(
          snapshot: snapshot,
          onChanged: (values) => edits = values,
          onOpenSource: (_) {},
        ));
    await tester.pumpWidget(editor(source));
    await enter(tester, 'gname_en', 'My unsaved title');
    await tester.pumpWidget(editor(revise(source, fields: {
      ...source.form.fields,
      'gname_en': fieldValue(source.form.fields['gname_en']!, ['Remote title']),
      'gname_jp':
          fieldValue(source.form.fields['gname_jp']!, ['Remote original']),
    })));
    await tester.pump();
    expect(tester.widget<TextField>(control('gname_en')).controller!.text,
        'My unsaved title');
    expect(tester.widget<TextField>(control('gname_jp')).controller!.text,
        'Remote original');
    expect(edits!['gname_en'], ['My unsaved title']);
  });

  testWidgets(
      'refresh that revokes a dirty field preserves it and blocks submission',
      (tester) async {
    final source = newSnapshot();
    Widget editor(UploadEditorSnapshot snapshot) => host(UploadEditorForm(
          snapshot: snapshot,
          initialValues: completeDraft,
          onChanged: (_) {},
          onSave: () {},
          onOpenSource: (_) {},
        ));
    await tester.pumpWidget(editor(source));
    await enter(tester, 'gname_en', 'Still local');
    await tester.pumpWidget(editor(revise(source, fields: {
      ...source.form.fields,
      'gname_en': fieldValue(source.form.fields['gname_en']!, ['Server title'],
          readOnly: true),
    })));
    expect(tester.widget<TextField>(control('gname_en')).controller!.text,
        'Still local');
    expect(
        find.byKey(const ValueKey('upload-editor-conflict')), findsOneWidget);
    expect(tester.widget<FilledButton>(action('save')).onPressed, isNull);
  });

  testWidgets(
      'matching saved values acknowledge edits even if permission tightens',
      (tester) async {
    final source = newSnapshot();
    Widget editor(UploadEditorSnapshot snapshot) => host(UploadEditorForm(
          snapshot: snapshot,
          initialValues: completeDraft,
          onChanged: (_) {},
          onSave: () {},
          onOpenSource: (_) {},
        ));
    await tester.pumpWidget(editor(source));
    final saved = revise(source, fields: {
      ...source.form.fields,
      'gname_en': fieldValue(source.form.fields['gname_en']!, ['Example work'],
          readOnly: true),
      'category': fieldValue(source.form.fields['category']!, ['9']),
      'langtag': fieldValue(source.form.fields['langtag']!, ['1058']),
      'langtype': fieldValue(source.form.fields['langtype']!, ['0']),
      'tos': fieldValue(source.form.fields['tos']!, ['on']),
    });
    await tester.pumpWidget(editor(saved));
    expect(find.byKey(const ValueKey('upload-editor-conflict')), findsNothing);
    expect(tester.widget<FilledButton>(action('save')).onPressed, isNotNull);
    // A further refresh must not replace explicit choices with unchosen defaults.
    await tester.pumpWidget(editor(revise(saved)));
    expect(tester.widget<FilledButton>(action('save')).onPressed, isNotNull);
  });

  testWidgets('refresh never accepts unchosen new-gallery defaults',
      (tester) async {
    final source = newSnapshot();
    Map<String, List<String>>? edits;
    Widget editor(UploadEditorSnapshot snapshot) => host(UploadEditorForm(
          snapshot: snapshot,
          onChanged: (values) => edits = values,
          onSave: () {},
          onOpenSource: (_) {},
        ));
    await tester.pumpWidget(editor(source));
    await tester.pumpWidget(editor(revise(source)));
    await tester.pump();
    expect(edits!['category'], isEmpty);
    expect(edits!['langtag'], isEmpty);
    expect(edits!['langtype'], isEmpty);
    expect(edits!['tos'], isEmpty);
  });

  testWidgets(
      'changed field types are not interpreted as editable business data',
      (tester) async {
    final source = newSnapshot();
    Map<String, List<String>>? edits;
    await tester.pumpWidget(host(UploadEditorForm(
      snapshot: revise(source, fields: {
        ...source.form.fields,
        'gname_en': const UploadField(
            name: 'gname_en',
            type: 'hidden',
            values: ['private-token-not-a-title']),
      }),
      initialValues: completeDraft,
      onChanged: (values) => edits = values,
      onSave: () {},
      onOpenSource: (_) {},
    )));
    await tester.pump();
    expect(control('gname_en'), findsNothing);
    expect(find.textContaining('private-token-not-a-title'), findsNothing);
    expect(edits!.keys, isNot(contains('gname_en')));
    expect(tester.widget<FilledButton>(action('save')).onPressed, isNull);
  });

  testWidgets(
      'removed choices do not crash or silently replace a saved selection',
      (tester) async {
    final source = newSnapshot();
    final reduced = revise(source, fields: {
      ...source.form.fields,
      'category': fieldValue(source.form.fields['category']!, ['2'],
          options: const [UploadOption('2', 'Doujinshi')]),
    });
    Map<String, List<String>>? edits;
    await tester.pumpWidget(host(UploadEditorForm(
      snapshot: reduced,
      initialValues: completeDraft,
      onChanged: (values) => edits = values,
      onSave: () {},
      onOpenSource: (_) {},
    )));
    await tester.pump();
    expect(edits!['category'], ['9']);
    expect(find.text('The previous option is unavailable. Choose again.'),
        findsOneWidget);
    expect(tester.widget<FilledButton>(action('save')).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'switching gallery identity loads its data instead of old dirty input',
      (tester) async {
    final source = newSnapshot();
    Widget editor(UploadEditorSnapshot snapshot) => host(UploadEditorForm(
          snapshot: snapshot,
          onChanged: (_) {},
          onOpenSource: (_) {},
        ));
    await tester.pumpWidget(editor(source));
    await enter(tester, 'gname_en', 'First gallery unsaved');
    await tester.pumpWidget(editor(revise(
      source,
      uri: Uri.parse('https://upld.e-hentai.org/managegallery?ulgid=456'),
      fields: {
        ...source.form.fields,
        'gname_en':
            fieldValue(source.form.fields['gname_en']!, ['Second gallery']),
      },
    )));
    expect(tester.widget<TextField>(control('gname_en')).controller!.text,
        'Second gallery');
    expect(find.text('First gallery unsaved'), findsNothing);
  });

  testWidgets(
      'new folder takes visible precedence while retaining site field values',
      (tester) async {
    Map<String, List<String>>? edits;
    await tester.pumpWidget(host(UploadEditorForm(
      snapshot: newSnapshot(),
      onChanged: (values) => edits = values,
      onOpenSource: (_) {},
    )));
    await enter(tester, 'foldername', 'New collection');
    expect(edits!['foldername'], ['New collection']);
    expect(edits!['folderid'], ['0']);
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(control('folderid'))
            .onChanged,
        isNull);
    expect(find.textContaining('Saving creates and uses this folder'),
        findsOneWidget);
    await enter(tester, 'foldername', '');
    expect(
        tester
            .widget<DropdownButtonFormField<String>>(control('folderid'))
            .onChanged,
        isNotNull);
  });

  testWidgets(
      'description preview formats BBCode but never loads HTML or remote images',
      (tester) async {
    var sources = 0;
    await tester.pumpWidget(host(UploadEditorForm(
      snapshot: newSnapshot(),
      initialValues: const {
        ...completeDraft,
        'ulcomment': [
          '[b]Bold[/b] [i]Italic[/i] <script>unsafe()</script> '
              '[url=https://example.com]Link[/url] [img]https://example.com/pic.png[/img]'
        ],
      },
      onChanged: (_) {},
      onOpenSource: (_) => sources++,
    )));
    await tapControl(tester,
        find.byKey(const ValueKey('upload-description-preview-toggle')));
    final preview = find.byKey(const ValueKey('upload-description-preview'));
    final rich = tester.widget<SelectableText>(
        find.descendant(of: preview, matching: find.byType(SelectableText)));
    final plain = rich.textSpan!.toPlainText();
    expect(plain, contains('Bold Italic'));
    expect(plain, contains('<script>unsafe()</script>'));
    expect(plain, contains('Link (https://example.com)'));
    expect(plain, contains('[Image: https://example.com/pic.png]'));
    expect(find.descendant(of: preview, matching: find.byType(Image)),
        findsNothing);
    expect(sources, 0);
    final bold = rich.textSpan!.children!.whereType<TextSpan>().first;
    expect(bold.style!.fontWeight, FontWeight.bold);
  });

  testWidgets('server capability and busy state gate otherwise-valid actions',
      (tester) async {
    final source = newSnapshot();
    final ready = revise(
      source,
      buttons: {
        ...source.buttons,
        'publishbutton': const UploadButton('Publish Gallery', true, null),
      },
      metadata: {...source.metadata, 'Uploaded Files': '2'},
    );
    Widget editor(bool busy, UploadEditorSnapshot snapshot) =>
        host(UploadEditorForm(
          snapshot: snapshot,
          initialValues: completeDraft,
          busy: busy,
          onChanged: (_) {},
          onSave: () {},
          onUpload: () {},
          onPublish: () {},
          onOpenSource: (_) {},
        ));
    await tester.pumpWidget(editor(false, ready));
    expect(tester.widget<FilledButton>(action('publish')).onPressed, isNotNull);
    await tester.pumpWidget(editor(true, ready));
    for (final name in ['save', 'upload', 'publish']) {
      expect(tester.widget<FilledButton>(action(name)).onPressed, isNull);
    }
    expect(tester.widget<TextField>(control('gname_en')).readOnly, isTrue);
    expect(tester.widget<CheckboxListTile>(control('tos')).onChanged, isNull);
    final restricted = revise(ready, buttons: {
      ...ready.buttons,
      'savebutton': const UploadButton('Save', false, 'Gallery is locked.'),
    });
    await tester.pumpWidget(editor(false, restricted));
    expect(tester.widget<FilledButton>(action('save')).onPressed, isNull);
    expect(
        find.text('Website explanation: Gallery is locked.'), findsOneWidget);
  });

  testWidgets(
      'rules are beside editor sections and upload does not stand in for unlock',
      (tester) async {
    final source = newSnapshot();
    final snapshot = revise(source, buttons: {
      'savebutton': source.buttons['savebutton']!,
      'unlockbutton': const UploadButton('Unlock', true, null),
    });
    await tester.pumpWidget(host(UploadEditorForm(
      snapshot: snapshot,
      onChanged: (_) {},
      onOpenSource: (_) {},
      files: const Text('Chosen file list'),
    )));
    for (final id in [
      'title',
      'category',
      'privateGallery',
      'aiDeclaration',
      'language',
      'translation',
      'folders',
      'description',
      'drafts',
      'rightsAndTerms',
      'cloneUpdate',
      'bumpLimit',
      'agedGallery',
    ]) {
      expect(find.byKey(ValueKey('upload-rule-$id')), findsOneWidget);
    }
    expect(find.text('Chosen file list'), findsOneWidget);
    expect(action('upload'), findsNothing);
    expect(find.textContaining('Create an updated version'), findsWidgets);
  });

  testWidgets('Chinese editor fits narrow screens with large text',
      (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(host(
        UploadEditorForm(
          snapshot: newSnapshot(),
          initialValues: Map.of(completeDraft)..['langtype'] = const ['1'],
          onChanged: (_) {},
          onSave: () {},
          onOpenSource: (_) {},
        ),
        language: 'zh',
        scale: 2));
    expect(find.text('翻译'), findsOneWidget);
    expect(find.text('由熟练人工译者翻译（非机器翻译）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
