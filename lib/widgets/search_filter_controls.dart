import 'package:flutter/material.dart';
import '../core/constants/app_constants.dart';

/// Shared entry point and category choices for search and cloud favorites.
class SearchFilterAction extends StatelessWidget {
  final String heroTag;
  final String? tooltip;
  final VoidCallback? onPressed;
  const SearchFilterAction(
      {super.key,
      required this.heroTag,
      this.tooltip,
      required this.onPressed});
  @override
  Widget build(BuildContext context) => FloatingActionButton.small(
      heroTag: heroTag,
      tooltip: tooltip,
      onPressed: onPressed,
      child: const Icon(Icons.tune));
}

class GalleryCategoryFilters extends StatelessWidget {
  final List<String> selected;
  final void Function(String, bool) onSelected;
  const GalleryCategoryFilters(
      {super.key, required this.selected, required this.onSelected});
  @override
  Widget build(BuildContext context) => Wrap(
      spacing: 6,
      runSpacing: 6,
      children: AppConstants.categories
          .map((category) => FilterChip(
              key: ValueKey('gallery-category-$category'),
              label: Text(category),
              selected: selected.contains(category),
              selectedColor:
                  Color(AppConstants.categoryColors[category] ?? 0xFF607D8B)
                      .withOpacity(.25),
              showCheckmark: false,
              onSelected: (value) => onSelected(category, value)))
          .toList());
}
