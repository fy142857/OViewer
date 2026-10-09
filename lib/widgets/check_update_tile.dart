import 'package:flutter/material.dart';
import 'dart:async';
import '../blocs/update/update_cubit.dart';
import 'android_update_dialog.dart';

import '../core/l10n/s.dart';
import '../repositories/update_repository.dart';

class CheckUpdateTile extends StatefulWidget {
  const CheckUpdateTile({
    super.key,
    required this.repository,
    required this.openRelease,
    this.androidUpdater,
  });

  final UpdateRepository repository;
  final Future<bool> Function(Uri) openRelease;
  final UpdateCubit? androidUpdater;

  @override
  State<CheckUpdateTile> createState() => _CheckUpdateTileState();
}

class _CheckUpdateTileState extends State<CheckUpdateTile> {
  UpdateCheckOperation? _operation;
  bool _busy = false;
  bool _checking = false;
  StreamSubscription<ApkUpdateState>? _updates;

  @override
  void initState() {
    super.initState();
    _restoreUpdateStatus();
    _updates = widget.androidUpdater?.stream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _restoreUpdateStatus() async {
    await widget.repository.restoreUpdateStatus();
    if (mounted) setState(() {});
  }

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
    if (widget.androidUpdater != null) {
      setState(() => _busy = true);
      final updater = widget.androidUpdater!;
      unawaited(updater.check());
      await showDialog<void>(
          context: context,
          builder: (_) => AndroidUpdateDialog(
              cubit: updater, openRelease: widget.openRelease));
      if (mounted) setState(() => _busy = false);
      return;
    }
    setState(() {
      _busy = true;
      _checking = true;
    });
    try {
      _operation = widget.repository.check();
      final result = await _operation!.result;
      if (!mounted) return;
      if (!_visible) return;
      setState(() => _checking = false);
      final s = S.of(context);
      switch (result.status) {
        case UpdateStatus.available:
          final version =
              result.version!.replaceFirst(RegExp(r'^v'), '').split('+').first;
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(s.updateAvailable),
              content: Text(s.updateInstallPrompt(version)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(s.cancel)),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(s.confirm)),
              ],
            ),
          );
          if (confirmed == true && _visible) await _open(result.releaseUrl!);
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
        UpdateFailure.storage => s.updateStorageFailed,
      };
      _message(message,
          action: SnackBarAction(
              label: s.retry,
              onPressed: () {
                if (_visible) _check();
              }));
    } finally {
      _operation = null;
      if (mounted) {
        setState(() {
          _busy = false;
          _checking = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _operation?.cancel();
    _updates?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ListTile(
      key: const ValueKey('check-update'),
      leading: const Icon(Icons.system_update),
      title: Text(s.checkUpdate),
      subtitle:
          Text(widget.androidUpdater?.state.phase == ApkUpdatePhase.downloading
              ? s.updateDownloading
              : widget.androidUpdater?.state.phase == ApkUpdatePhase.ready
                  ? s.installNow
                  : _checking
                      ? s.checkingUpdate
                      : s.checkUpdateHint),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.repository.updateAvailable) ...[
            Text(s.updateAvailable,
                key: const ValueKey('update-available-badge'),
                style: const TextStyle(color: Colors.purple)),
            const SizedBox(width: 8),
          ],
          _checking
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.chevron_right),
        ],
      ),
      onTap: _busy ? null : _check,
    );
  }
}
