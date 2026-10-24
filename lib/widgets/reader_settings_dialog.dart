import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/settings/settings_bloc.dart';
import '../blocs/settings/settings_event.dart';
import '../blocs/settings/settings_state.dart';
import '../core/l10n/s.dart';
import '../models/reader_page_layout.dart';

Future<void> showReaderSettings(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => BlocProvider.value(
        value: context.read<SettingsBloc>(),
        child: const ReaderSettingsDialog()));

class ReaderSettingsDialog extends StatelessWidget {
  const ReaderSettingsDialog({super.key});
  @override
  Widget build(BuildContext context) =>
      BlocBuilder<SettingsBloc, SettingsState>(builder: (context, state) {
        final s = S.of(context);
        return AlertDialog(
          title: Text(s.readerSettings),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<int>(
                key: const ValueKey('reader-direction'),
                value: state.readingMode,
                isExpanded: true,
                decoration: InputDecoration(labelText: s.readingDirection),
                items: [
                  for (final item in {
                    0: s.leftToRight,
                    1: s.rightToLeft,
                    2: s.verticalScroll
                  }.entries)
                    DropdownMenuItem(value: item.key, child: Text(item.value)),
                ],
                onChanged: (value) {
                  if (value != null)
                    context.read<SettingsBloc>().add(UpdateReadingMode(value));
                },
              ),
              const SizedBox(height: 20),
              DropdownButtonFormField<ReaderPageLayout>(
                key: const ValueKey('reader-page-layout'),
                value: state.pageLayout,
                isExpanded: true,
                decoration: InputDecoration(labelText: s.readerPageLayout),
                items: [
                  DropdownMenuItem(
                      value: ReaderPageLayout.single,
                      child: Text(s.readerSinglePage)),
                  DropdownMenuItem(
                      value: ReaderPageLayout.doublePage,
                      child: Text(s.readerDoublePage)),
                ],
                onChanged: (value) {
                  if (value != null)
                    context
                        .read<SettingsBloc>()
                        .add(UpdateReaderPageLayout(value));
                },
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(s.closeReaderSettings))
          ],
        );
      });
}
