import 'dart:async';
import 'package:flutter/material.dart';
import '../core/l10n/s.dart';
import '../core/services/offline_download_coordinator.dart';
import '../repositories/settings_repository.dart';

class OfflineSettingsPanel extends StatefulWidget {
  final SettingsRepository settings;
  final OfflineDownloadCoordinator coordinator;
  const OfflineSettingsPanel(
      {super.key, required this.settings, required this.coordinator});
  @override
  State<OfflineSettingsPanel> createState() => _OfflineSettingsPanelState();
}

class _OfflineSettingsPanelState extends State<OfflineSettingsPanel> {
  late int _galleries;
  late int _pages;
  bool _saving = false;
  int? _bytes;
  bool _sizeFailed = false;
  int _generation = 0;
  StreamSubscription<void>? _changes;
  @override
  void initState() {
    super.initState();
    _galleries = widget.settings.getOfflineParallelGalleries();
    _pages = widget.settings.getOfflineParallelPages();
    _changes = widget.coordinator.changes.listen((_) => _size());
    _size();
  }

  Future<void> _size() async {
    final generation = ++_generation;
    try {
      final bytes = await widget.coordinator.repository.size();
      if (mounted && generation == _generation)
        setState(() {
          _bytes = bytes;
          _sizeFailed = false;
        });
    } catch (_) {
      if (mounted && generation == _generation)
        setState(() => _sizeFailed = true);
    }
  }

  Future<void> _set(int value, bool galleries) async {
    setState(() => _saving = true);
    try {
      if (galleries)
        await widget.settings.setOfflineParallelGalleries(value);
      else
        await widget.settings.setOfflineParallelPages(value);
      if (galleries)
        _galleries = value;
      else
        _pages = value;
      widget.coordinator.configure(galleries: _galleries, pages: _pages);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).offlineSettingsFailed)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(children: [
      ListTile(
          leading: const Icon(Icons.offline_pin_outlined),
          title: Text(s.offlineCache),
          subtitle: Text(
              '${_sizeFailed ? s.cacheSizeUnavailable : _bytes == null ? s.calculatingCacheSize : '${(_bytes! / 1048576).toStringAsFixed(1)} MB'}\n${s.offlineStorageHint}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.pushNamed(context, '/downloads')),
      ListTile(
          title: Text(s.offlineParallelGalleries),
          trailing: DropdownButton<int>(
              key: const ValueKey('offline-parallel-galleries'),
              value: _galleries,
              items: [
                for (var n = 1; n <= 3; n++)
                  DropdownMenuItem(value: n, child: Text('$n'))
              ],
              onChanged: _saving
                  ? null
                  : (n) {
                      if (n != null) _set(n, true);
                    })),
      ListTile(
          title: Text(s.offlineParallelPages),
          subtitle: Text(s.offlineParallelHint),
          trailing: DropdownButton<int>(
              key: const ValueKey('offline-parallel-pages'),
              value: _pages,
              items: [
                for (var n = 1; n <= 6; n++)
                  DropdownMenuItem(value: n, child: Text('$n'))
              ],
              onChanged: _saving
                  ? null
                  : (n) {
                      if (n != null) _set(n, false);
                    })),
    ]);
  }
}
