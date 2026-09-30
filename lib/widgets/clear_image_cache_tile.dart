import 'package:flutter/material.dart';
import '../core/l10n/s.dart';

class ClearImageCacheTile extends StatefulWidget {
  final Future<void> Function() onClear;
  final Future<int> Function() readSize;
  final Listenable? changes;
  final bool Function()? cleanupFailed;
  final Future<void> Function()? retryCleanup;
  const ClearImageCacheTile(
      {super.key,
      required this.onClear,
      required this.readSize,
      this.changes,
      this.cleanupFailed,
      this.retryCleanup});

  @override
  State<ClearImageCacheTile> createState() => _ClearImageCacheTileState();
}

class _ClearImageCacheTileState extends State<ClearImageCacheTile> {
  bool _clearing = false;
  int? _bytes;
  bool _sizeFailed = false;
  int _sizeRequest = 0;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    _refreshSize();
    widget.changes?.addListener(_refreshSize);
  }

  @override
  void didUpdateWidget(covariant ClearImageCacheTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      oldWidget.changes?.removeListener(_refreshSize);
      widget.changes?.addListener(_refreshSize);
      _refreshSize();
    }
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_refreshSize);
    super.dispose();
  }

  Future<void> _retryCleanup() async {
    if (_retrying || _clearing) return;
    setState(() => _retrying = true);
    try {
      await widget.retryCleanup?.call();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).cacheClearFailed)));
      }
    } finally {
      if (mounted) {
        await _refreshSize();
        if (mounted) setState(() => _retrying = false);
      }
    }
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
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_clearing
            ? s.clearingCache
            : _sizeFailed
                ? s.cacheSizeUnavailable
                : _bytes == null
                    ? s.calculatingCacheSize
                    : _formatBytes(_bytes!)),
        if (widget.cleanupFailed?.call() == true)
          TextButton(
              key: const ValueKey('retry-cache-quota'),
              onPressed: _retrying || _clearing ? null : _retryCleanup,
              child: Text(s.cacheQuotaFailed)),
      ]),
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
