import 'package:flutter/material.dart';
import '../core/l10n/s.dart';
import '../core/utils/tag_search_query.dart';
import '../core/utils/uploader_search_query.dart';
import '../models/gallery_tag.dart';
import 'tag_chip.dart';

class GalleryTagSection extends StatelessWidget {
  final List<GalleryTag> tags;
  final String uploader;
  final ValueChanged<String> onSearch;

  const GalleryTagSection(
      {super.key,
      required this.tags,
      required this.uploader,
      required this.onSearch});

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<GalleryTag>>{};
    for (final tag in tags) {
      grouped.putIfAbsent(tag.namespace, () => []).add(tag);
    }
    final rows = grouped.entries.toList();
    final name = uploader.trim();
    if (name.isNotEmpty) {
      final other = rows.indexWhere((entry) => entry.key == 'other');
      rows.insert(other < 0 ? rows.length : other + 1,
          MapEntry('uploader', [GalleryTag(namespace: 'uploader', key: name)]));
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(S.of(context).tags, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      for (final entry in rows)
        Padding(
          key: ValueKey('gallery-tags-${entry.key}'),
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
                width: 72,
                child: Text('${entry.key}:',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.outline))),
            Expanded(
                child: Wrap(spacing: 4, runSpacing: 4, children: [
              for (final tag in entry.value) _chip(tag),
            ])),
          ]),
        ),
    ]);
  }

  Widget _chip(GalleryTag tag) {
    final isUploader = tag.namespace == 'uploader';
    final query = isUploader
        ? uploaderSearchQuery(tag.key)
        : exactTagQuery(tag.namespace, tag.key);
    return TagChip(
        tag: tag,
        showTranslation: !isUploader,
        onTap: query == null ? null : () => onSearch(query));
  }
}
