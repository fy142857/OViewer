import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/settings/settings_bloc.dart';
import '../blocs/settings/settings_event.dart';
import '../blocs/settings/settings_state.dart';
import '../core/l10n/s.dart';
import '../models/reader_page_layout.dart';

/// Shared by the settings page and the reader menu.
class ReaderPreloadSetting extends StatefulWidget {
  const ReaderPreloadSetting({super.key, this.compact = false});
  final bool compact;
  @override
  State<ReaderPreloadSetting> createState() => _ReaderPreloadSettingState();
}

class _ReaderPreloadSettingState extends State<ReaderPreloadSetting> {
  bool _choosing = false;

  Future<void> _choose(SettingsState state) async {
    if (_choosing || state.savingPreloadCount) return;
    setState(() => _choosing = true);
    final bloc = context.read<SettingsBloc>();
    final s = S.of(context);
    try {
      final selected = await showDialog<int>(
          context: context,
          builder: (dialog) => SimpleDialog(
                title: Text(s.readerPreloadCount),
                children: [
                  for (var n = 1; n <= 5; n++)
                    RadioListTile<int>(
                        key: ValueKey('reader-preload-option-$n'),
                        value: n,
                        groupValue: state.preloadCount,
                        title: Text(s.readerPreloadLabel(n,
                            state.pageLayout == ReaderPageLayout.doublePage)),
                        onChanged: (value) => Navigator.pop(dialog, value)),
                ],
              ));
      if (selected == null || !mounted || bloc.state.savingPreloadCount) return;
      final done = Completer<void>();
      bloc.add(UpdateReaderPreloadCount(selected, completer: done));
      await done.future;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(s.readerPreloadSaveFailed)));
      }
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<SettingsBloc, SettingsState>(builder: (context, state) {
        final s = S.of(context);
        return ListTile(
          key: const ValueKey('reader-preload-count'),
          dense: widget.compact,
          contentPadding: widget.compact ? EdgeInsets.zero : null,
          leading: const Icon(Icons.download_for_offline_outlined),
          title: Text(s.readerPreloadCount),
          subtitle: Text(s.readerPreloadLabel(state.preloadCount,
              state.pageLayout == ReaderPageLayout.doublePage)),
          trailing: state.savingPreloadCount
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.chevron_right),
          enabled: !_choosing && !state.savingPreloadCount,
          onTap: () => _choose(state),
        );
      });
}
