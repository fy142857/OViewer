import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/settings/settings_bloc.dart';
import '../blocs/settings/settings_event.dart';
import '../blocs/settings/settings_state.dart';
import '../core/l10n/s.dart';
import '../models/reader_page_layout.dart';

class ReaderSettingsButton extends StatelessWidget {
  const ReaderSettingsButton({super.key});
  @override
  Widget build(BuildContext context) => PopupMenuButton<void>(
        key: const ValueKey('reader-settings'),
        icon: const Icon(Icons.auto_stories, color: Colors.white),
        tooltip: S.of(context).readerSettings,
        position: PopupMenuPosition.under,
        constraints: const BoxConstraints(minWidth: 264, maxWidth: 300),
        itemBuilder: (_) => [
          PopupMenuItem<void>(
            enabled: false,
            child: BlocProvider.value(
                value: context.read<SettingsBloc>(),
                child: const ReaderSettingsOptions()),
          )
        ],
      );
}

class ReaderSettingsOptions extends StatelessWidget {
  const ReaderSettingsOptions({super.key});
  @override
  Widget build(BuildContext context) =>
      BlocBuilder<SettingsBloc, SettingsState>(
        builder: (context, state) {
          final s = S.of(context);
          return Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<int>(
              key: const ValueKey('reader-direction'),
              value: state.readingMode,
              isExpanded: true,
              isDense: false,
              itemHeight: null,
              decoration: InputDecoration(labelText: s.readingDirection),
              items: [
                for (final item in {
                  0: s.leftToRight,
                  1: s.rightToLeft,
                  2: s.verticalScroll
                }.entries)
                  DropdownMenuItem(value: item.key, child: Text(item.value))
              ],
              onChanged: (value) {
                if (value != null)
                  context.read<SettingsBloc>().add(UpdateReadingMode(value));
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<ReaderPageLayout>(
              key: const ValueKey('reader-page-layout'),
              value: state.pageLayout,
              isExpanded: true,
              isDense: false,
              itemHeight: null,
              decoration: InputDecoration(labelText: s.readerPageLayout),
              items: [
                DropdownMenuItem(
                    value: ReaderPageLayout.single,
                    child: Text(s.readerSinglePage)),
                DropdownMenuItem(
                    value: ReaderPageLayout.doublePage,
                    child: Text(s.readerDoublePage))
              ],
              onChanged: (value) {
                if (value != null)
                  context
                      .read<SettingsBloc>()
                      .add(UpdateReaderPageLayout(value));
              },
            ),
            if (state.readingMode == 2 &&
                state.pageLayout == ReaderPageLayout.doublePage) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<ReaderSpreadAlignment>(
                key: const ValueKey('reader-spread-alignment'),
                value: state.spreadAlignment,
                isExpanded: true,
                isDense: false,
                itemHeight: null,
                decoration: InputDecoration(labelText: s.readerSpreadAlignment),
                items: [
                  DropdownMenuItem(
                      value: ReaderSpreadAlignment.width,
                      child: Text(s.readerAlignWidth)),
                  DropdownMenuItem(
                      value: ReaderSpreadAlignment.height,
                      child: Text(s.readerAlignHeight))
                ],
                onChanged: (value) {
                  if (value != null)
                    context
                        .read<SettingsBloc>()
                        .add(UpdateReaderSpreadAlignment(value));
                },
              ),
            ],
          ]);
        },
      );
}
