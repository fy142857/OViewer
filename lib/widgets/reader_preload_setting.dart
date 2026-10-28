import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/settings/settings_bloc.dart';
import '../blocs/settings/settings_event.dart';
import '../blocs/settings/settings_state.dart';
import '../core/l10n/s.dart';

/// Shared by the settings page and the reader toolbar.
class ReaderPreloadSetting extends StatefulWidget {
  const ReaderPreloadSetting({super.key, this.toolbar = false});
  final bool toolbar;
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
                        title: Text('$n'),
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
        final enabled = !_choosing && !state.savingPreloadCount;
        if (widget.toolbar) {
          return Tooltip(
            message: s.readerPreloadCount,
            child: Semantics(
              label: s.readerPreloadCount,
              value: '${state.preloadCount}',
              child: TextButton(
                key: const ValueKey('reader-preload-button'),
                style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 8)),
                onPressed: enabled ? () => _choose(state) : null,
                child: state.savingPreloadCount
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        Text('${state.preloadCount}'),
                        const Icon(Icons.arrow_drop_down, size: 20),
                      ]),
              ),
            ),
          );
        }
        return ListTile(
          key: const ValueKey('reader-preload-count'),
          leading: const Icon(Icons.download_for_offline_outlined),
          title: Text(s.readerPreloadCount),
          subtitle: Text('${state.preloadCount}'),
          trailing: state.savingPreloadCount
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.chevron_right),
          enabled: enabled,
          onTap: () => _choose(state),
        );
      });
}
