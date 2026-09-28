import 'package:flutter/material.dart';
import '../core/l10n/s.dart';

class ClearImageCacheTile extends StatefulWidget {
  final Future<void> Function() onClear;
  final Future<int> Function() readSize;
  const ClearImageCacheTile(
      {super.key, required this.onClear, required this.readSize});

  @override
  State<ClearImageCacheTile> createState() => _ClearImageCacheTileState();
}

class _ClearImageCacheTileState extends State<ClearImageCacheTile> {
  bool _clearing = false;
  int? _bytes;
  bool _sizeFailed = false;
  int _sizeRequest = 0;

  @override
  void initState() {
    super.initState();
    _refreshSize();
  }

  Future<void> _refreshSize() async {
    final request = ++_sizeRequest;
    try {
      final bytes = await widget.readSize();
      if (mounted && request == _sizeRequest) {
        setState(() {
          _bytes = bytes;
          _sizeFailed = false;
        });
      }
    } catch (_) {
      if (mounted && request == _sizeRequest) {
        setState(() {
          _bytes = null;
          _sizeFailed = true;
        });
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  Future<void> _clear() async {
    if (_clearing) return;
    _sizeRequest++; // Discard a size read started before this cleanup.
    setState(() => _clearing = true);
    var succeeded = false;
    try {
      await widget.onClear();
      succeeded = true;
    } catch (_) {
      // Report failure without exposing file paths or claiming success.
    } finally {
      if (mounted) {
        await _refreshSize();
        if (mounted) {
          setState(() => _clearing = false);
          final s = S.of(context);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(succeeded ? s.cacheCleared : s.cacheClearFailed)));
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ListTile(
      key: const ValueKey('clear-image-cache'),
      leading: const Icon(Icons.cached),
      title: Text(s.imageCache),
      subtitle: Text(_clearing
          ? s.clearingCache
          : _sizeFailed
              ? s.cacheSizeUnavailable
              : _bytes == null
                  ? s.calculatingCacheSize
                  : _formatBytes(_bytes!)),
      trailing: _clearing
          ? SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                  strokeWidth: 2, semanticsLabel: s.clearingCache))
          : TextButton(onPressed: _clear, child: Text(s.clear)),
    );
  }
}
