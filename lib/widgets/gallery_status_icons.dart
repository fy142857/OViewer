import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/download/download_bloc.dart';
import '../blocs/settings/settings_bloc.dart';
import '../core/l10n/s.dart';
import '../models/gallery_preview.dart';
import '../models/gallery_source.dart';

/// Shared indicators for gallery lists and cover grids. DownloadBloc supplies
/// live state, so completion, deletion and source changes update visible tiles.
class GalleryStatusIcons extends StatelessWidget {
  final GalleryPreview gallery;
  final bool decorated;
  const GalleryStatusIcons(
      {super.key, required this.gallery, this.decorated = false});

  @override
  Widget build(BuildContext context) {
    final source =
        context.select<SettingsBloc?, GallerySource>((bloc) => bloc == null
            ? GallerySource.current
            : bloc.state.useExHentai
                ? GallerySource.ex
                : GallerySource.eh);
    final cacheState = context.select<DownloadBloc?, int>((bloc) {
      final matches = bloc?.state.tasks.where((book) =>
            book.source == source &&
            book.record.gid == gallery.gid &&
            book.record.token == gallery.token &&
            book.complete);
      if (matches == null || matches.isEmpty) return 0;
      return matches.any((book) => book.allPagesComplete) ? 2 : 1;
    });
    final cached = cacheState > 0;
    Widget badge(IconData icon, Color color, {String? label}) {
      Widget child = Icon(icon, size: decorated ? 16 : 14, color: color);
      if (decorated) {
        child = DecoratedBox(
            decoration: const BoxDecoration(
                color: Colors.white, shape: BoxShape.circle),
            child: Padding(padding: const EdgeInsets.all(3), child: child));
      }
      return label == null ? child : Tooltip(message: label, child: child);
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (cached)
        badge(Icons.offline_pin, Colors.green,
            label: cacheState == 2 ? S.of(context).offlineCached
                : S.of(context).downloadRangeCompleted),
      if (cached && gallery.isFavorited) const SizedBox(width: 4),
      if (gallery.isFavorited) badge(Icons.favorite, Colors.red),
    ]);
  }
}
