import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/settings/settings_bloc.dart';
import '../blocs/settings/settings_event.dart';
import '../blocs/settings/settings_state.dart';
import '../core/l10n/s.dart';
import '../models/reader_page_layout.dart';

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
      if (selected != null && mounted) await _persist(selected);
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  Future<void> _persist(int value) async {
    final bloc = context.read<SettingsBloc>();
    if (bloc.state.savingPreloadCount) return;
    try {
      final done = Completer<void>();
      bloc.add(UpdateReaderPreloadCount(value, completer: done));
      await done.future;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).readerPreloadSaveFailed)));
      }
    }
  }

  Future<void> _chooseMenu(SettingsState state) async {
    if (_choosing || context.read<SettingsBloc>().state.savingPreloadCount)
      return;
    setState(() => _choosing = true);
    try {
      final s = S.of(context);
      final theme = Theme.of(context);
      final overlay = Navigator.of(context).overlay!.context.findRenderObject()!
          as RenderBox;
      final anchor = context.findRenderObject()! as RenderBox;
      final bounds =
          anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size;
      final below = (overlay.size.height -
              MediaQuery.of(context).padding.bottom -
              8 -
              bounds.bottom)
          .clamp(0.0, overlay.size.height);
      final doublePage = state.pageLayout == ReaderPageLayout.doublePage;
      final selected = await showMenu<int>(
        context: context,
        position: RelativeRect.fromRect(
            Rect.fromLTWH(bounds.left, bounds.bottom, bounds.width, 0),
            Offset.zero & overlay.size),
        constraints:
            BoxConstraints(minWidth: 220, maxWidth: 260, maxHeight: below),
        color: theme.colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        // Do not use initialValue: it recenters the menu on the selected row.
        items: [
          PopupMenuItem<int>(
            key: const ValueKey('reader-preload-title'),
            enabled: false,
            child: Row(children: [
              Icon(Icons.autorenew,
                  size: 20, color: theme.colorScheme.onSurface),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(s.readerPreloadCount,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(color: theme.colorScheme.onSurface))),
            ]),
          ),
          for (var n = 1; n <= 5; n++)
            PopupMenuItem<int>(
              key: ValueKey('reader-preload-option-$n'),
              value: n,
              child: Row(children: [
                Expanded(child: Text(s.readerPreloadLabel(n, doublePage))),
                if (state.preloadCount == n)
                  const Icon(Icons.check, size: 18, color: Colors.blue),
              ]),
            ),
        ],
      );
      if (selected != null && mounted) await _persist(selected);
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<SettingsBloc, SettingsState>(builder: (context, state) {
        final s = S.of(context);
        final enabled = !_choosing && !state.savingPreloadCount;
        final doublePage = state.pageLayout == ReaderPageLayout.doublePage;
        if (widget.toolbar) {
          return Semantics(
              value: s.readerPreloadLabel(state.preloadCount, doublePage),
              child: IconButton(
                key: const ValueKey('reader-preload-button'),
                tooltip: s.readerPreloadCount,
                onPressed: enabled ? () => _chooseMenu(state) : null,
                icon: state.savingPreloadCount
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.autorenew, color: Colors.white),
              ));
        }
        return ListTile(
          key: const ValueKey('reader-preload-count'),
          leading: const Icon(Icons.autorenew),
          title: Text(s.readerPreloadCount),
          subtitle: Text(s.readerPreloadLabel(state.preloadCount, doublePage)),
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
