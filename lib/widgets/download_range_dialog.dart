import 'package:flutter/material.dart';
import '../core/l10n/s.dart';
import '../models/download_range.dart';

class DownloadRangeDialog extends StatefulWidget {
  final String title;
  final String source;
  final int totalPages;
  final bool enabled;
  const DownloadRangeDialog(
      {super.key,
      required this.title,
      required this.source,
      required this.totalPages,
      required this.enabled});

  @override
  State<DownloadRangeDialog> createState() => _DownloadRangeDialogState();
}

class _DownloadRangeDialogState extends State<DownloadRangeDialog> {
  final _input = TextEditingController();
  bool _all = true;
  DownloadRange? _selection = const DownloadRange.all();
  String? _error;

  void _validate() {
    setState(() {
      _error = null;
      if (!_all && _input.text.trim().isEmpty) {
        _selection = null;
        return;
      }
      try {
        _selection = _all
            ? const DownloadRange.all()
            : DownloadRange.parse(_input.text, widget.totalPages);
      } on FormatException catch (error) {
        _selection = null;
        _error = error.message;
      }
    });
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final colors = Theme.of(context).colorScheme;
    final labelColor = _error == null ? colors.onSurfaceVariant : colors.error;
    return AlertDialog(
      title: Text(s.startDownloadConfirm),
      scrollable: true,
      content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title),
            const SizedBox(height: 12),
            Text(s.offlineDownloadFrom(widget.source, widget.totalPages)),
            RadioListTile<bool>(
                value: true,
                groupValue: _all,
                contentPadding: EdgeInsets.zero,
                title: Text(s.downloadAllPages),
                onChanged: (_) {
                  _all = true;
                  _validate();
                }),
            RadioListTile<bool>(
                value: false,
                groupValue: _all,
                contentPadding: EdgeInsets.zero,
                title: Text(s.downloadCustomRange),
                onChanged: (_) {
                  _all = false;
                  _validate();
                }),
            if (!_all)
              TextField(
                  key: const ValueKey('download-range-input'),
                  controller: _input,
                  keyboardType: TextInputType.text,
                  decoration: InputDecoration(
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      labelText: s.downloadCustomRange,
                      labelStyle: TextStyle(color: labelColor),
                      floatingLabelStyle: TextStyle(color: labelColor),
                      hintText: '1-20,35,50-60',
                      helperText: _input.text.trim().isEmpty
                          ? s.downloadRangeError(
                              'range_empty', widget.totalPages)
                          : null,
                      helperStyle: TextStyle(color: colors.onSurfaceVariant),
                      helperMaxLines: 3,
                      errorMaxLines: 3,
                      errorText: _error == null
                          ? null
                          : s.downloadRangeError(_error!, widget.totalPages)),
                  onChanged: (_) => _validate()),
            const SizedBox(height: 12),
            if (_selection != null)
              Text(s
                  .downloadSelectedPages(_selection!.count(widget.totalPages))),
            const SizedBox(height: 8),
            Text(s.downloadRangeMergeHint,
                style: Theme.of(context).textTheme.bodySmall),
          ]),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
        FilledButton(
            key: const ValueKey('confirm-download-range'),
            onPressed:
                widget.enabled && widget.totalPages > 0 && _selection != null
                    ? () => Navigator.pop(context, _selection)
                    : null,
            child: Text(s.download)),
      ],
    );
  }
}
