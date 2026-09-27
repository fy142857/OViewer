import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/reader/reader_bloc.dart';
import '../blocs/reader/reader_state.dart';
import '../core/l10n/s.dart';

class ReaderPageMenu extends StatelessWidget {
  final int page;
  final ValueListenable<Set<int>> savingPages;
  const ReaderPageMenu(
      {super.key, required this.page, required this.savingPages});
  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return BlocBuilder<ReaderBloc, ReaderState>(
        builder: (context, state) => ValueListenableBuilder<Set<int>>(
            valueListenable: savingPages,
            builder: (context, saving, _) => SimpleDialog(
                    title: Text(s.readerPageTitle(page + 1)),
                    children: [
                      SimpleDialogOption(
                          key: const ValueKey('reload-page'),
                          onPressed: () => Navigator.pop(context, 'reload'),
                          child: Text(s.reloadPage)),
                      if (state.readyResources[page] != null)
                        SimpleDialogOption(
                            key: const ValueKey('save-page'),
                            onPressed: saving.contains(page)
                                ? null
                                : () => Navigator.pop(
                                    context, state.readyResources[page]),
                            child: Text(saving.contains(page)
                                ? s.savingPage
                                : s.savePage)),
                      SimpleDialogOption(
                          onPressed: () => Navigator.pop(context),
                          child: Text(s.cancel)),
                    ])));
  }
}
