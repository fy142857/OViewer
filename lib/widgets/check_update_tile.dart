import 'package:flutter/material.dart';

import '../core/l10n/s.dart';
import '../repositories/update_repository.dart';

class CheckUpdateTile extends StatefulWidget {
  const CheckUpdateTile({
    super.key,
    required this.repository,
    required this.openRelease,
  });

  final UpdateRepository repository;
  final Future<bool> Function(Uri) openRelease;

  @override
  State<CheckUpdateTile> createState() => _CheckUpdateTileState();
}

class _CheckUpdateTileState extends State<CheckUpdateTile> {
  UpdateCheckOperation? _operation;
  bool _busy = false;

  bool get _visible => mounted && (ModalRoute.of(context)?.isCurrent ?? true);

  void _message(String text, {SnackBarAction? action}) {
    if (!_visible) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), action: action));
  }

  Future<void> _open(Uri url) async {
    bool opened;
    try {
      opened = await widget.openRelease(url);
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    if (!_visible || opened) return;
    final s = S.of(context);
    _message(s.releaseOpenFailed,
        action: SnackBarAction(
            label: s.reopenRelease,
            onPressed: () {
              if (_visible && !_busy) _retryOpen(url);
            }));
  }

  Future<void> _retryOpen(Uri url) async {
    setState(() => _busy = true);
    await _open(url);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _check() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _operation = widget.repository.check();
      final result = await _operation!.result;
      if (!mounted) return;
      if (!_visible) return;
      final s = S.of(context);
      switch (result.status) {
        case UpdateStatus.available:
          await _open(result.releaseUrl!);
          break;
        case UpdateStatus.current:
          _message(s.versionCurrent);
          break;
        case UpdateStatus.ahead:
          _message(s.versionAhead);
          break;
        case UpdateStatus.noRelease:
          _message(s.noReleaseAvailable);
          break;
      }
    } catch (error) {
      if (!mounted) return;
      if (!_visible) return;
      final s = S.of(context);
      final failure =
          error is UpdateCheckException ? error.failure : UpdateFailure.network;
      final message = switch (failure) {
        UpdateFailure.network => s.updateNetworkFailed,
        UpdateFailure.timeout => s.updateTimedOut,
        UpdateFailure.rateLimited => s.updateRateLimited,
        UpdateFailure.invalidResponse => s.updateInvalidResponse,
        UpdateFailure.version => s.versionUnavailable,
      };
      _message(message,
          action: SnackBarAction(
              label: s.retry,
              onPressed: () {
                if (_visible) _check();
              }));
    } finally {
      _operation = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _operation?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ListTile(
      key: const ValueKey('check-update'),
      leading: const Icon(Icons.system_update),
      title: Text(s.checkUpdate),
      subtitle: Text(_busy ? s.checkingUpdate : s.checkUpdateHint),
      trailing: _busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.chevron_right),
      onTap: _busy ? null : _check,
    );
  }
}
