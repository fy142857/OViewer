import 'package:flutter/material.dart';
import '../core/l10n/s.dart';
import '../repositories/settings_repository.dart';

/// Choosing a destination changes the preference; the heart performs the action.
class GalleryFavoriteButtons extends StatefulWidget {
  final SettingsRepository settings;
  final bool isFavorited;
  final ValueChanged<int> onToggle;

  const GalleryFavoriteButtons(
      {super.key,
      required this.settings,
      required this.isFavorited,
      required this.onToggle});

  @override
  State<GalleryFavoriteButtons> createState() => _GalleryFavoriteButtonsState();
}

class _GalleryFavoriteButtonsState extends State<GalleryFavoriteButtons> {
  bool _choosing = false;

  Future<void> _choose() async {
    setState(() => _choosing = true);
    final s = S.of(context);
    try {
      final current = widget.settings.getFavoriteDestination();
      final selected = await showModalBottomSheet<int>(
        context: context,
        builder: (context) => SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
              padding: const EdgeInsets.all(16),
              child: Text(s.favoriteDestination,
                  style: Theme.of(context).textTheme.titleMedium)),
          Flexible(
              child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(bottom: 48),
                  children: [
                for (var slot = 0; slot <= 9; slot++)
                  ListTile(
                      key: ValueKey('favorite-destination-$slot'),
                      title: Text(s.favoriteCategory(slot)),
                      selected: current == slot,
                      trailing:
                          current == slot ? const Icon(Icons.check) : null,
                      onTap: () => Navigator.pop(context, slot)),
              ])),
        ])),
      );
      if (selected != null && mounted && selected != current) {
        await widget.settings.setFavoriteDestination(selected);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s.favoriteDestinationSaveFailed)));
      }
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final destination =
        '${s.favoriteDestination}: ${s.favoriteCategory(widget.settings.getFavoriteDestination())}';
    return Column(mainAxisSize: MainAxisSize.min, children: [
      IconButton.outlined(
          key: const ValueKey('choose-favorite-destination'),
          tooltip: destination,
          onPressed: _choosing ? null : _choose,
          icon: const Icon(Icons.menu, size: 20)),
      const SizedBox(height: 4),
      IconButton.outlined(
          key: const ValueKey('toggle-gallery-favorite'),
          tooltip: widget.isFavorited ? s.removeFavorite : destination,
          onPressed: _choosing
              ? null
              : () => widget.onToggle(widget.settings.getFavoriteDestination()),
          icon: Icon(
              widget.isFavorited ? Icons.favorite : Icons.favorite_border,
              size: 20,
              color: widget.isFavorited ? Colors.red : null)),
    ]);
  }
}
