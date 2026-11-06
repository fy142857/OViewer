import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/settings/settings_bloc.dart';
import '../blocs/settings/settings_event.dart';
import '../blocs/settings/settings_state.dart';
import '../core/l10n/s.dart';
import '../models/reader_page_layout.dart';

Future<void> saveReaderTransition(
    BuildContext context, ReaderPageTransition value) async {
  final done = Completer<void>();
  context.read<SettingsBloc>().add(UpdateReaderPageTransition(value, done));
  try {
    await done.future;
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.of(context).readerTransitionSaveFailed)));
    }
  }
}

class ReaderTransitionSetting extends StatelessWidget {
  const ReaderTransitionSetting({super.key});
  @override
  Widget build(BuildContext context) =>
      BlocBuilder<SettingsBloc, SettingsState>(builder: (context, state) {
        final s = S.of(context);
        String label(ReaderPageTransition value) =>
            value == ReaderPageTransition.none
                ? s.readerTransitionNone
                : s.readerTransitionSlide;
        return ListTile(
            key: const ValueKey('settings-reader-transition'),
            leading: const Icon(Icons.swipe),
            title: Text(s.readerPageTransition),
            subtitle: Text(
                '${label(state.pageTransition)} · ${s.readerTransitionHint}'),
            trailing: const Icon(Icons.chevron_right),
            enabled: !state.savingPageTransition,
            onTap: () async {
              final value = await showDialog<ReaderPageTransition>(
                  context: context,
                  builder: (dialog) => SimpleDialog(
                          title: Text(s.readerPageTransition),
                          children: [
                            for (final value in ReaderPageTransition.values)
                              RadioListTile<ReaderPageTransition>(
                                  value: value,
                                  groupValue: state.pageTransition,
                                  title: Text(label(value)),
                                  onChanged: (value) =>
                                      Navigator.pop(dialog, value)),
                          ]));
              if (value != null && context.mounted) {
                await saveReaderTransition(context, value);
              }
            });
      });
}
