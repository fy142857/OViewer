import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/upload_protocol.dart';
import '../rules/rule_notice.dart';
import '../rules/upload_rules.dart';

/// Native controls for a current, server-derived editor snapshot.
///
/// The parent owns scrolling, network operations, draft persistence, file
/// selection, and final publication confirmation. Use a different widget key
/// when loading another local draft that has the same new-gallery URL.
/// [onChanged] contains only recognized editable business fields, never hidden
/// controls, authentication fields, or upload bodies.
class UploadEditorForm extends StatefulWidget {
  final UploadEditorSnapshot snapshot;
  final Map<String, List<String>>? initialValues;
  final ValueChanged<Map<String, List<String>>> onChanged;
  final VoidCallback? onSave;
  final VoidCallback? onUpload;
  final VoidCallback? onPublish;
  final FutureOr<void> Function(Uri) onOpenSource;
  final bool busy;
  final Widget? files;

  const UploadEditorForm({
    super.key,
    required this.snapshot,
    this.initialValues,
    required this.onChanged,
    this.onSave,
    this.onUpload,
    this.onPublish,
    required this.onOpenSource,
    this.busy = false,
    this.files,
  });

  @override
  State<UploadEditorForm> createState() => _UploadEditorFormState();
}

class _UploadEditorFormState extends State<UploadEditorForm> {
  static const _names = {
    'gname_en',
    'gname_jp',
    'category',
    'aigen',
    'langtag',
    'langtype',
    'langctl',
    'folderid',
    'foldername',
    'ulcomment',
    'tos',
  };
  static const _textNames = {
    'gname_en',
    'gname_jp',
    'foldername',
    'ulcomment',
  };
  static const _newChoices = {'category', 'langtag', 'langtype', 'tos'};
  static const _expectedTypes = {
    'gname_en': 'text',
    'gname_jp': 'text',
    'category': 'select',
    'aigen': 'checkbox',
    'langtag': 'select',
    'langtype': 'radio',
    'langctl': 'checkbox',
    'folderid': 'select',
    'foldername': 'text',
    'ulcomment': 'textarea',
    'tos': 'checkbox',
  };

  final _values = <String, List<String>>{};
  final _dirty = <String>{};
  final _explicitChoices = <String>{};
  final _controllers = <String, TextEditingController>{};
  final _previousFields = <String, UploadField>{};
  var _emissionRevision = 0;
  var _descriptionExpanded = false;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _l(String zh, String en) => _zh ? zh : en;
  UploadField? _field(String name) => widget.snapshot.form.fields[name];
  UploadField? _displayField(String name) =>
      _field(name) ?? _previousFields[name];
  bool _supported(UploadField field) =>
      _expectedTypes[field.name] == field.type;
  bool _exists(String name) =>
      (_field(name) != null && _supported(_field(name)!)) ||
      (_dirty.contains(name) && _previousFields.containsKey(name));
  bool _editable(String name) =>
      !widget.busy &&
      _field(name)?.canEdit == true &&
      _supported(_field(name)!);
  String _value(String name) =>
      (_values[name]?.isNotEmpty ?? false) ? _values[name]!.first : '';
  bool _checked(String name) => _values[name]?.isNotEmpty ?? false;
  bool _sameValues(List<String> left, List<String> right) =>
      left.length == right.length &&
      Iterable<int>.generate(left.length)
          .every((index) => left[index] == right[index]);

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void didUpdateWidget(UploadEditorForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changedGallery = oldWidget.snapshot.uri.removeFragment() !=
        widget.snapshot.uri.removeFragment();
    if (changedGallery) {
      _load(reset: true);
    } else if (!identical(oldWidget.snapshot, widget.snapshot)) {
      _load(reset: false);
    }
  }

  void _load({required bool reset}) {
    if (reset) {
      _values.clear();
      _dirty.clear();
      _explicitChoices.clear();
      _previousFields.clear();
      _descriptionExpanded = false;
    }
    for (final name in _names) {
      final field = _field(name);
      if (field == null || !_supported(field)) continue;
      _previousFields[name] = field;
      if (!reset && _dirty.contains(name)) {
        final retained = _values[name] ?? const <String>[];
        if (_sameValues(retained, field.values)) {
          // A matching refreshed value acknowledges the edit without replacing
          // user input. This also allows permissions to tighten after saving.
          _dirty.remove(name);
        }
        continue;
      }
      final restored = reset ? (widget.initialValues?[name]) : null;
      if (restored != null && _newChoices.contains(name)) {
        _explicitChoices.add(name);
      }
      final values = restored ??
          (widget.snapshot.isNew &&
                  _newChoices.contains(name) &&
                  !_explicitChoices.contains(name)
              ? const <String>[]
              : field.values);
      _values[name] = List.of(values);
      if (restored != null && !_sameValues(restored, field.values)) {
        _dirty.add(name);
      }
    }
    if (_value('langtype') != '1' && _field('langctl')?.canEdit == true) {
      _values['langctl'] = [];
    }
    for (final name in _textNames) {
      final controller =
          _controllers.putIfAbsent(name, () => TextEditingController());
      if (controller.text != _value(name)) controller.text = _value(name);
    }
    final revision = ++_emissionRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && revision == _emissionRevision) _emit();
    });
  }

  Map<String, List<String>> _edits() => Map.unmodifiable({
        for (final name in _names)
          if (_field(name)?.canEdit == true && _supported(_field(name)!))
            name: List<String>.unmodifiable(_values[name] ?? const []),
      });

  void _emit() => widget.onChanged(_edits());

  void _change(String name, List<String> values) {
    if (!_editable(name)) return;
    setState(() {
      _setValue(name, values);
      if (name == 'langtype' &&
          _value('langtype') != '1' &&
          _field('langctl')?.canEdit == true) {
        _setValue('langctl', []);
      }
      if (name == 'aigen') _updateAiTitle(_checked('aigen'));
    });
    _emit();
  }

  void _setValue(String name, List<String> values) {
    _values[name] = List.of(values);
    _dirty.add(name);
    if (_newChoices.contains(name)) _explicitChoices.add(name);
    final controller = _controllers[name];
    if (controller != null && controller.text != _value(name)) {
      controller.value = TextEditingValue(
        text: _value(name),
        selection: TextSelection.collapsed(offset: _value(name).length),
      );
    }
  }

  String _withoutAiIndicator(String title) => title
      .replaceAll(RegExp(r'\[?AI(-| )?Generated\]?', caseSensitive: false), '')
      .replaceFirst(RegExp(r'\s+'), ' ')
      .trim();

  void _updateAiTitle(bool checked) {
    if (_field('gname_en')?.canEdit != true) return;
    final title = _withoutAiIndicator(_value('gname_en'));
    _setValue('gname_en', ['$title${checked ? ' [AI Generated]' : ''}']);
  }

  String _checkboxValue(String name) => _field(name)!
      .options
      .firstWhere((option) => !option.disabled,
          orElse: () => const UploadOption('on', ''))
      .value;

  List<String> get _conflicts => [
        for (final name in _dirty)
          if (_field(name)?.canEdit != true || !_supported(_field(name)!)) name,
      ];

  String? _invalid(String name) {
    final field = _field(name);
    if (field == null || !_supported(field)) return null;
    final values = _values[name] ?? const <String>[];
    if (field.maxLength != null &&
        values.any((v) => v.runes.length > field.maxLength!)) {
      return _l('超过站点允许的 ${field.maxLength} 个字符。',
          'Exceeds the website limit of ${field.maxLength} characters.');
    }
    if (!field.canEdit) return null;
    if (values.length > 1) {
      return _l('请选择一个值。', 'Choose one value.');
    }
    if (field.options.isNotEmpty &&
        values.any(
            (v) => !field.options.any((o) => o.value == v && !o.disabled))) {
      return _l('原选项已不可用，请重新选择。',
          'The previous option is unavailable. Choose again.');
    }
    if (field.type == 'checkbox' &&
        values.isNotEmpty &&
        values.single != _checkboxValue(name)) {
      return _l('请重新确认此选项。', 'Confirm this option again.');
    }
    return null;
  }

  List<String> get _incomplete {
    final missing = <String>[];
    if (_withoutAiIndicator(_value('gname_en')).isEmpty) {
      missing.add(_label('gname_en'));
    }
    for (final name in ['category', 'langtag', 'langtype']) {
      if ((widget.snapshot.isNew || _field(name)?.canEdit == true) &&
          _value(name).isEmpty) missing.add(_label(name));
    }
    if ((widget.snapshot.isNew || _exists('tos')) && !_checked('tos')) {
      missing.add(_l('同意服务条款', 'agreement to the Terms of Service'));
    }
    return missing;
  }

  bool get _valid =>
      _incomplete.isEmpty &&
      _conflicts.isEmpty &&
      _names.every((name) => _invalid(name) == null) &&
      (_value('langtype') == '1' || !_checked('langctl'));

  String _label(String name) => switch (name) {
        'gname_en' => _l('主标题', 'Main title'),
        'gname_jp' => _l('原文标题', 'Original title'),
        'category' => _l('分类', 'Category'),
        'aigen' => _l('主要内容由 AI 生成', 'Primarily AI-generated content'),
        'langtag' => _l('作品语言', 'Work language'),
        'langtype' => _l('语言类型', 'Language type'),
        'langctl' => _l('由熟练人工译者翻译（非机器翻译）',
            'By a proficient human translator (not machine translated)'),
        'folderid' => _l('已有目录', 'Existing folder'),
        'foldername' => _l('或新建目录', 'Or create a folder'),
        'ulcomment' => _l('画廊描述', 'Gallery description'),
        'tos' => _l('我已阅读并同意 E-Hentai 服务条款',
            'I have read and agree to the E-Hentai Terms of Service'),
        _ => name,
      };

  String _optionLabel(String name, UploadOption option) {
    if (!_zh) return option.label;
    if (name == 'langtype') {
      return switch (option.value) {
        '0' => '正式发行／无文本',
        '1' => '翻译',
        '2' => '改写',
        _ => option.label,
      };
    }
    const labels = {
      'Doujinshi': '同人志',
      'Manga': '漫画',
      'Artist CG': '画师 CG',
      'Game CG': '游戏 CG',
      'Western': '西方作品',
      'Non-H': '非色情作品',
      'Image Set': '图集',
      'Cosplay': '角色扮演',
      'Misc': '其他',
      '(Private / Unlisted)': '私人／不公开列出',
      'Unsorted': '未分类',
      'No Text': '无文本',
      'Japanese': '日语',
      'Chinese': '中文',
      'English': '英语',
      'French': '法语',
      'Italian': '意大利语',
      'Korean': '韩语',
      'Portuguese': '葡萄牙语',
      'Russian': '俄语',
      'Spanish': '西班牙语',
      'Thai': '泰语',
      'Albanian': '阿尔巴尼亚语',
      'Arabic': '阿拉伯语',
      'Bengali': '孟加拉语',
      'Bulgarian': '保加利亚语',
      'Burmese': '缅甸语',
      'Catalan': '加泰罗尼亚语',
      'Cebuano': '宿务语',
      'Croatian': '克罗地亚语',
      'Czech': '捷克语',
      'Danish': '丹麦语',
      'Dutch': '荷兰语',
      'Esperanto': '世界语',
      'Finnish': '芬兰语',
      'German': '德语',
      'Greek': '希腊语',
      'Hebrew': '希伯来语',
      'Hindi': '印地语',
      'Hungarian': '匈牙利语',
      'Indonesian': '印度尼西亚语',
      'Javanese': '爪哇语',
      'Latin': '拉丁语',
      'Norwegian': '挪威语',
      'Persian': '波斯语',
      'Polish': '波兰语',
      'Romanian': '罗马尼亚语',
      'Serbian': '塞尔维亚语',
      'Slovak': '斯洛伐克语',
      'Swedish': '瑞典语',
      'Tagalog': '他加禄语',
      'Turkish': '土耳其语',
      'Ukrainian': '乌克兰语',
      'Vietnamese': '越南语',
    };
    return labels[option.label] ?? option.label;
  }

  Widget _rule(UploadRuleId id) => RuleNotice(
        rule: UploadRules.byId(id),
        onOpenSource: widget.onOpenSource,
      );

  Widget _restriction(String name) {
    if (_field(name)?.canEdit == true && _supported(_field(name)!)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        _l('网站当前不允许修改此字段；以当前站内权限为准。',
            'The website currently makes this field unavailable for editing.'),
        key: ValueKey('upload-field-restriction-$name'),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }

  Widget _text(String name, {int lines = 1}) {
    final field = _displayField(name)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: ValueKey('upload-field-$name'),
          controller: _controllers[name],
          readOnly: !_editable(name),
          minLines: lines,
          maxLines: lines == 1 ? 1 : 12,
          maxLength: field.maxLength,
          maxLengthEnforcement: MaxLengthEnforcement.none,
          keyboardType:
              lines == 1 ? TextInputType.text : TextInputType.multiline,
          textCapitalization: TextCapitalization.none,
          decoration: InputDecoration(
            labelText: '${_label(name)}${name == 'gname_en' ? ' *' : ''}',
            border: const OutlineInputBorder(),
            errorText: _invalid(name),
          ),
          onChanged: (value) => _change(name, [value]),
        ),
        _restriction(name),
      ],
    );
  }

  Widget _select(String name, {bool extraEnabled = true}) {
    final field = _displayField(name)!;
    final options = <String, UploadOption>{
      for (final option in field.options) option.value: option,
    };
    final selected = options.containsKey(_value(name)) ? _value(name) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('upload-field-$name'),
          value: selected,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: '${_label(name)}${name == 'folderid' ? '' : ' *'}',
            border: const OutlineInputBorder(),
            errorText: _invalid(name),
          ),
          hint: Text(_l('请选择', 'Choose an option')),
          items: [
            for (final option in options.values)
              DropdownMenuItem<String>(
                value: option.value,
                enabled: !option.disabled,
                child: Text(_optionLabel(name, option),
                    overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: _editable(name) && extraEnabled
              ? (value) {
                  if (value != null) _change(name, [value]);
                }
              : null,
        ),
        _restriction(name),
      ],
    );
  }

  Widget _checkbox(String name, {bool extraEnabled = true}) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CheckboxListTile(
            key: ValueKey('upload-field-$name'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(_label(name)),
            value: _checked(name),
            onChanged: _editable(name) && extraEnabled
                ? (value) =>
                    _change(name, value == true ? [_checkboxValue(name)] : [])
                : null,
          ),
          if (_invalid(name) != null) Text(_invalid(name)!),
          _restriction(name),
        ],
      );

  Widget _languageType() {
    final field = _displayField('langtype')!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${_label('langtype')} *',
            style: Theme.of(context).textTheme.titleSmall),
        for (final option in field.options)
          RadioListTile<String>(
            key: ValueKey('upload-langtype-${option.value}'),
            contentPadding: EdgeInsets.zero,
            title: Text(_optionLabel('langtype', option)),
            value: option.value,
            groupValue: _value('langtype'),
            onChanged: _editable('langtype') && !option.disabled
                ? (value) {
                    if (value != null) _change('langtype', [value]);
                  }
                : null,
          ),
        if (_invalid('langtype') != null) Text(_invalid('langtype')!),
        _restriction('langtype'),
      ],
    );
  }

  Widget _action(String id, String label, VoidCallback? callback,
      {bool publish = false}) {
    final server = widget.snapshot.buttons[id];
    final remoteFiles = widget.snapshot.images.isNotEmpty ||
        (int.tryParse((widget.snapshot.metadata['Uploaded Files'] ?? '')
                    .replaceAll(',', '')) ??
                0) >
            0;
    final nonempty = !publish || remoteFiles;
    final enabled = !widget.busy &&
        _valid &&
        nonempty &&
        callback != null &&
        server?.enabled == true;
    final reason = !nonempty
        ? _l('站点还没有确认接收任何图片，不能发布空画廊。',
            'No images have been confirmed on the website. An empty gallery cannot be published.')
        : server?.enabled != true
            ? _l('站点当前不允许此操作。',
                'The website does not currently allow this action.')
            : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          key: ValueKey('upload-action-$id'),
          onPressed: enabled
              ? () {
                  _emit();
                  callback();
                }
              : null,
          child: Text(label),
        ),
        if (reason != null) Text(reason),
        if (server?.enabled == false && (server?.reason?.isNotEmpty ?? false))
          Text('${_l('站点说明', 'Website explanation')}: ${server!.reason}',
              key: ValueKey('upload-action-reason-$id')),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_conflicts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                '${_l('站点权限已改变，以下本地修改已保留但暂不能提交', 'Website permissions changed. These local edits are retained but cannot be submitted')}: ${_conflicts.map(_label).join(', ')}',
                key: const ValueKey('upload-editor-conflict'),
              ),
            ),
          if (_exists('gname_en')) _text('gname_en'),
          if (_exists('gname_jp')) ...[
            const SizedBox(height: 12),
            _text('gname_jp'),
          ],
          _rule(UploadRuleId.title),
          const SizedBox(height: 12),
          if (_exists('category')) _select('category'),
          _rule(UploadRuleId.category),
          _rule(UploadRuleId.privateGallery),
          if (_exists('aigen')) ...[
            _checkbox('aigen', extraEnabled: _editable('gname_en')),
            Text('${_l('标题预览', 'Title preview')}: ${_value('gname_en')}',
                key: const ValueKey('upload-ai-title-preview')),
            _rule(UploadRuleId.aiDeclaration),
          ],
          const SizedBox(height: 12),
          if (_exists('langtag')) _select('langtag'),
          _rule(UploadRuleId.language),
          if (_exists('langtype')) _languageType(),
          if (_exists('langctl') && _value('langtype') == '1')
            _checkbox('langctl'),
          _rule(UploadRuleId.translation),
          const SizedBox(height: 12),
          if (_exists('folderid'))
            _select('folderid',
                extraEnabled: _value('foldername').trim().isEmpty),
          if (_exists('foldername')) ...[
            const SizedBox(height: 12),
            _text('foldername'),
            if (_value('foldername').trim().isNotEmpty)
              Text(_l('保存时将新建并使用此目录，已有目录选择不再使用。',
                  'Saving creates and uses this folder instead of the existing-folder selection.')),
          ],
          _rule(UploadRuleId.folders),
          const SizedBox(height: 12),
          if (_exists('ulcomment')) ...[
            _text('ulcomment', lines: 4),
            TextButton.icon(
              key: const ValueKey('upload-description-preview-toggle'),
              onPressed: () =>
                  setState(() => _descriptionExpanded = !_descriptionExpanded),
              icon: Icon(
                  _descriptionExpanded ? Icons.expand_less : Icons.expand_more),
              label: Text(_l('描述预览', 'Description preview')),
            ),
            if (_descriptionExpanded)
              Container(
                key: const ValueKey('upload-description-preview'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText.rich(TextSpan(
                      children: _bbcode(_value('ulcomment').length > 20000
                          ? _value('ulcomment').substring(0, 20000)
                          : _value('ulcomment')),
                    )),
                    if (_value('ulcomment').length > 20000)
                      Text(_l('预览仅展示前 20,000 个字符，保存内容不会截断。',
                          'The preview shows the first 20,000 characters; saved text is not truncated.')),
                    const SizedBox(height: 8),
                    Text(_l('仅预览基本 BBCode；链接与图片以文字显示，不加载外部内容。',
                        'Basic BBCode preview only. Links and images are shown as text without loading external content.')),
                  ],
                ),
              ),
          ],
          _rule(UploadRuleId.description),
          _rule(UploadRuleId.drafts),
          if (!widget.snapshot.isNew) _rule(UploadRuleId.editing),
          if (widget.snapshot.buttons.containsKey('unlockbutton')) ...[
            Text(_l('修改图片前需要先创建更新版本；请使用页面的更新入口。',
                'Create an updated version before changing images, using this page’s update action.')),
            _rule(UploadRuleId.cloneUpdate),
            _rule(UploadRuleId.bumpLimit),
            _rule(UploadRuleId.agedGallery),
          ],
          if (widget.files != null) ...[
            const SizedBox(height: 16),
            widget.files!,
          ],
          if (_exists('tos')) _checkbox('tos'),
          _rule(UploadRuleId.rightsAndTerms),
          if (widget.snapshot.buttons.containsKey('publishbutton')) ...[
            _rule(UploadRuleId.contentChecks),
            _rule(UploadRuleId.publication),
          ],
          if (_incomplete.isNotEmpty)
            Text(
              '${_l('提交前请完成', 'Complete before submitting')}: ${_incomplete.join(', ')}',
              key: const ValueKey('upload-editor-incomplete'),
            ),
          if (widget.busy)
            Text(_l('操作进行中，请等待站点确认。',
                'Operation in progress. Wait for the website to confirm.')),
          if (widget.snapshot.buttons.containsKey('savebutton') ||
              widget.onSave != null)
            _action(
                'savebutton', _l('保存到站点', 'Save to website'), widget.onSave),
          if (widget.snapshot.buttons.containsKey('uploadbutton') ||
              widget.onUpload != null) ...[
            const SizedBox(height: 8),
            _action(
                'uploadbutton', _l('开始上传', 'Start upload'), widget.onUpload),
          ],
          if (widget.snapshot.buttons.containsKey('publishbutton') ||
              widget.onPublish != null) ...[
            const SizedBox(height: 8),
            _action('publishbutton', _l('检查并发布', 'Review and publish'),
                widget.onPublish,
                publish: true),
          ],
        ],
      );

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }
}

/// Deliberately does not interpret HTML, fetch images, or activate links.
List<InlineSpan> _bbcode(String text, [int depth = 0]) {
  if (depth >= 12) return [TextSpan(text: text)];
  final pattern = RegExp(
      r'\[(b|i|u|s|url|img)(?:=([^\]\r\n]+))?\]([\s\S]*?)\[/\1\]',
      caseSensitive: false);
  final result = <InlineSpan>[];
  var offset = 0;
  for (final match in pattern.allMatches(text)) {
    if (match.start > offset) {
      result.add(TextSpan(text: text.substring(offset, match.start)));
    }
    final tag = match[1]!.toLowerCase();
    final body = match[3]!;
    if (tag == 'img') {
      result.add(TextSpan(text: '[Image: $body]'));
    } else if (tag == 'url') {
      final target = match[2] ?? body;
      result.add(TextSpan(
          text: target == body ? body : '$body ($target)',
          style: const TextStyle(decoration: TextDecoration.underline)));
    } else {
      final style = switch (tag) {
        'b' => const TextStyle(fontWeight: FontWeight.bold),
        'i' => const TextStyle(fontStyle: FontStyle.italic),
        'u' => const TextStyle(decoration: TextDecoration.underline),
        's' => const TextStyle(decoration: TextDecoration.lineThrough),
        _ => const TextStyle(),
      };
      result.add(TextSpan(style: style, children: _bbcode(body, depth + 1)));
    }
    offset = match.end;
  }
  if (offset < text.length) result.add(TextSpan(text: text.substring(offset)));
  return result;
}
