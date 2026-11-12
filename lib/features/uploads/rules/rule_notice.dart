import 'dart:async';

import 'package:flutter/material.dart';

import 'upload_rules.dart';

typedef UploadRuleSourceOpener = FutureOr<void> Function(Uri source);

/// Contextual rule help, including consequences that never collapse away.
class RuleNotice extends StatefulWidget {
  final UploadRule rule;
  final UploadRuleSourceOpener onOpenSource;
  final bool initiallyExpanded;

  const RuleNotice({
    super.key,
    required this.rule,
    required this.onOpenSource,
    this.initiallyExpanded = false,
  });

  @override
  State<RuleNotice> createState() => _RuleNoticeState();
}

class _RuleNoticeState extends State<RuleNotice> {
  late bool _expanded;
  bool _openingSource = false;
  String? _sourceError;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  void didUpdateWidget(RuleNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rule.id != widget.rule.id) {
      _expanded = widget.initiallyExpanded;
      _sourceError = null;
    }
  }

  Future<void> _open(UploadRuleSource source) async {
    if (_openingSource) return;
    final ruleId = widget.rule.id;
    setState(() {
      _openingSource = true;
      _sourceError = null;
    });
    try {
      await widget.onOpenSource(source.uri);
    } catch (_) {
      if (mounted && widget.rule.id == ruleId) {
        // The source URL is public; never display arbitrary exception details.
        setState(() => _sourceError = source.url);
      }
    } finally {
      if (mounted) setState(() => _openingSource = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = Localizations.localeOf(context).languageCode;
    final zh = language == 'zh';
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final rule = widget.rule;
    final danger = rule.severity == UploadRuleSeverity.danger;
    final caution = rule.severity == UploadRuleSeverity.caution;
    final accent = danger ? colors.error : colors.onSurfaceVariant;
    final icon =
        danger || caution ? Icons.warning_amber_rounded : Icons.info_outline;
    final kindLabel = switch (rule.kind) {
      UploadRuleKind.website => zh ? '站点规则' : 'Website rules',
      UploadRuleKind.application => zh ? '应用操作说明' : 'App behavior',
      UploadRuleKind.platform => zh ? '系统限制' : 'System limitations',
    };

    return Semantics(
      container: true,
      child: Container(
        key: ValueKey('upload-rule-${rule.id.name}'),
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: danger ? colors.errorContainer : colors.surfaceVariant,
          border: Border.all(color: accent.withOpacity(0.28)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    rule.title.inLanguage(language),
                    style: theme.textTheme.titleSmall?.copyWith(
                      color:
                          danger ? colors.onErrorContainer : colors.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(rule.summary.inLanguage(language)),
            for (final consequence in rule.alwaysVisible) ...[
              const SizedBox(height: 8),
              Text(
                consequence.inLanguage(language),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: danger ? colors.onErrorContainer : colors.onSurface,
                ),
              ),
            ],
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: ValueKey('upload-rule-toggle-${rule.id.name}'),
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                label: Text(_expanded
                    ? (zh ? '收起详细说明' : 'Hide details')
                    : (zh ? '查看详细说明' : 'Show details')),
              ),
            ),
            if (_expanded) ...[
              for (final paragraph in rule.details)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(paragraph.inLanguage(language)),
                ),
              Text(
                '$kindLabel · ${zh ? '核验日期' : 'Checked'} ${rule.checkedOn}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              for (var index = 0; index < rule.sources.length; index++)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: ValueKey('upload-rule-source-${rule.id.name}-$index'),
                    onPressed: _openingSource
                        ? null
                        : () => _open(rule.sources[index]),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: Text(
                      rule.sources[index].title.inLanguage(language),
                      softWrap: true,
                    ),
                  ),
                ),
              if (_sourceError != null)
                Semantics(
                  liveRegion: true,
                  child: SelectableText(
                    '${zh ? '无法打开来源，可复制链接后重试：' : 'Could not open the source. Copy the link to retry:'}\n$_sourceError',
                    key: ValueKey('upload-rule-source-error-${rule.id.name}'),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shows every applicable rule at its actual field or action location.
class RuleNotices extends StatelessWidget {
  final UploadRuleLocation location;
  final UploadRuleSourceOpener onOpenSource;
  final bool initiallyExpanded;

  const RuleNotices({
    super.key,
    required this.location,
    required this.onOpenSource,
    this.initiallyExpanded = false,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final rule in UploadRules.forLocation(location))
            RuleNotice(
              key: ValueKey(rule.id),
              rule: rule,
              onOpenSource: onOpenSource,
              initiallyExpanded: initiallyExpanded,
            ),
        ],
      );
}
