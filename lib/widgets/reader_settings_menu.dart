import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/settings/settings_bloc.dart';
import '../blocs/settings/settings_event.dart';
import '../blocs/settings/settings_state.dart';
import '../core/l10n/s.dart';
import '../models/reader_page_layout.dart';
import 'reader_preload_setting.dart';

class ReaderSettingsButton extends StatelessWidget {
  const ReaderSettingsButton({super.key});
  @override
  Widget build(BuildContext context) => PopupMenuButton<void>(
        key: const ValueKey('reader-settings'),
        icon: const Icon(Icons.auto_stories, color: Colors.white),
        tooltip: S.of(context).readerSettings,
        position: PopupMenuPosition.under,
        color: Theme.of(context).colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        constraints: const BoxConstraints(minWidth: 240, maxWidth: 300),
        itemBuilder: (_) => [
          _ReaderSettingsEntry(
              child: BlocProvider.value(
                  value: context.read<SettingsBloc>(),
                  child: const ReaderSettingsOptions()))
        ],
      );
}

class ReaderSettingsOptions extends StatelessWidget {
  const ReaderSettingsOptions({super.key});

  Widget _selector<T>(BuildContext context,
      {required String id,
      required String label,
      required T value,
      required Map<T, (String, IconData)> choices,
      required ValueChanged<T> onChanged}) {
    final theme = Theme.of(context);
    return Builder(
        key: ValueKey(id),
        builder: (anchorContext) => Semantics(
              label: label,
              value: choices[value]!.$1,
              button: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () async {
                  final overlay = Navigator.of(anchorContext)
                      .overlay!
                      .context
                      .findRenderObject()! as RenderBox;
                  final anchor = anchorContext.findRenderObject()! as RenderBox;
                  final bounds =
                      anchor.localToGlobal(Offset.zero, ancestor: overlay) &
                          anchor.size;
                  final media = MediaQuery.of(anchorContext);
                  final below = (overlay.size.height -
                          media.padding.bottom -
                          8 -
                          bounds.top)
                      .clamp(0.0, overlay.size.height);
                  final selected = await showMenu<T>(
                    context: anchorContext,
                    position: RelativeRect.fromRect(
                        bounds, Offset.zero & overlay.size),
                    // No initialValue: a selected item must not recenter the popup.
                    constraints: BoxConstraints(
                        minWidth: anchor.size.width,
                        maxWidth: anchor.size.width,
                        maxHeight: below),
                    color: theme.colorScheme.surface,
                    surfaceTintColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4)),
                    items: [
                      for (final entry in choices.entries)
                        PopupMenuItem<T>(
                            key: ValueKey('$id-option-${entry.key}'),
                            value: entry.key,
                            child: Row(children: [
                              Icon(entry.value.$2, size: 20),
                              const SizedBox(width: 8),
                              Expanded(child: Text(entry.value.$1)),
                              if (entry.key == value)
                                const Icon(Icons.check,
                                    size: 18, color: Colors.blue),
                            ])),
                    ],
                  );
                  if (selected != null && anchorContext.mounted)
                    onChanged(selected);
                },
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(children: [
                        Icon(choices[value]!.$2,
                            size: 20, color: theme.colorScheme.onSurface),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(choices[value]!.$1,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                    color: theme.colorScheme.onSurface))),
                        const SizedBox(width: 8),
                        Icon(Icons.arrow_drop_down,
                            color: theme.colorScheme.onSurface),
                      ])),
                ),
              ),
            ));
  }

  @override
  Widget build(BuildContext context) =>
      BlocBuilder<SettingsBloc, SettingsState>(builder: (context, state) {
        final s = S.of(context);
        final settings = context.read<SettingsBloc>();
        return Column(mainAxisSize: MainAxisSize.min, children: [
          _selector<int>(context,
              id: 'reader-direction',
              label: s.readingDirection,
              value: state.readingMode,
              choices: {
                0: (s.leftToRight, Icons.arrow_forward),
                1: (s.rightToLeft, Icons.arrow_back),
                2: (s.verticalScroll, Icons.swap_vert)
              },
              onChanged: (value) => settings.add(UpdateReadingMode(value))),
          _selector<ReaderPageLayout>(context,
              id: 'reader-page-layout',
              label: s.readerPageLayout,
              value: state.pageLayout,
              choices: {
                ReaderPageLayout.single: (
                  s.readerSinglePage,
                  Icons.crop_portrait
                ),
                ReaderPageLayout.doublePage: (
                  s.readerDoublePage,
                  Icons.auto_stories
                )
              },
              onChanged: (value) =>
                  settings.add(UpdateReaderPageLayout(value))),
          if (state.readingMode == 2 &&
              MediaQuery.orientationOf(context) == Orientation.landscape)
            _selector<ReaderSpreadAlignment>(context,
                id: 'reader-spread-alignment',
                label: s.readerSpreadAlignment,
                value: state.spreadAlignment,
                choices: {
                  ReaderSpreadAlignment.width: (
                    s.readerAlignWidth,
                    Icons.swap_horiz
                  ),
                  ReaderSpreadAlignment.height: (
                    s.readerAlignHeight,
                    Icons.height
                  )
                },
                onChanged: (value) =>
                    settings.add(UpdateReaderSpreadAlignment(value))),
          const ReaderPreloadSetting(compact: true),
        ]);
      });
}

class _ReaderSettingsEntry extends PopupMenuEntry<void> {
  const _ReaderSettingsEntry({required this.child});
  final Widget child;
  @override
  double get height => kMinInteractiveDimension;
  @override
  bool represents(void value) => false;
  @override
  State<_ReaderSettingsEntry> createState() => _ReaderSettingsEntryState();
}

class _ReaderSettingsEntryState extends State<_ReaderSettingsEntry> {
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16), child: widget.child);
}
