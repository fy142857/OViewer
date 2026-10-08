import 'package:flutter/material.dart';
import '../../core/l10n/s.dart';
import '../../widgets/favorites_content.dart';
import '../../widgets/favorites_filter_button.dart';

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text(S.of(context).favorites)),
      floatingActionButton: FavoritesFilterButton(
          heroTag: 'sidebar-favorites-filter',
          bottomInset: MediaQuery.of(context).viewPadding.bottom),
      body: const FavoritesContent(
          storageKey: 'sidebar-favorites', allowRemoval: true));
}
