import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/update/update_cubit.dart';
import '../core/l10n/s.dart';
import '../repositories/update_repository.dart';
import 'update_release_notes.dart';

Future<void> showAndroidUpdateDialog(BuildContext context,
    {required UpdateCubit cubit,
    required Future<bool> Function(Uri) openRelease}) async {
  if (cubit.windowVisible) return;
  cubit.windowOpened();
  try {
    await showDialog<void>(
        context: context,
        builder: (_) =>
            AndroidUpdateDialog(cubit: cubit, openRelease: openRelease));
  } finally {
    cubit.windowClosed();
  }
}

class AndroidUpdateDialog extends StatelessWidget {
  const AndroidUpdateDialog(
      {super.key, required this.cubit, required this.openRelease});
  final UpdateCubit cubit;
  final Future<bool> Function(Uri) openRelease;
  static String size(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) => BlocBuilder<UpdateCubit,
          ApkUpdateState>(
      bloc: cubit,
      builder: (context, state) {
        final s = S.of(context);
        final update = state.update;
        final result = state.result;
        final downloading = state.phase == ApkUpdatePhase.downloading;
        final pausing = state.phase == ApkUpdatePhase.pausing;
        final verifying = state.phase == ApkUpdatePhase.verifying;
        final checking = state.phase == ApkUpdatePhase.checking;
        final ready = state.phase == ApkUpdatePhase.ready;
        final interrupted = state.phase == ApkUpdatePhase.interrupted;
        final error = state.error ?? result?.apkFailure;
        final url = update?.releaseUrl ?? result?.releaseUrl;
        final notes = update?.notes ?? result?.notes ?? '';
        String? status;
        if (ready) status = s.updateReady;
        if (interrupted) status = s.updateInterrupted;
        if (interrupted && error == 'paused') status = s.paused;
        if (state.phase == ApkUpdatePhase.waitingPermission)
          status = s.updatePermission;
        if (result?.status == UpdateStatus.current) status = s.versionCurrent;
        if (result?.status == UpdateStatus.ahead) status = s.versionAhead;
        if (result?.status == UpdateStatus.noRelease)
          status = s.noReleaseAvailable;
        final retryInstall = state.path != null &&
            const ['permission', 'no_installer', 'unavailable'].contains(error);
        return AlertDialog(
          title: Text(downloading || pausing
              ? s.updateDownloading
              : verifying
                  ? s.updateVerifying
                  : s.checkUpdate),
          content: SizedBox(
              width: 400,
              child: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    if (url != null)
                      TextButton(
                          key: const ValueKey('update-release-link'),
                          onPressed: () async {
                            var opened = false;
                            try {
                              opened = await openRelease(url);
                            } catch (_) {}
                            if (!opened && context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(s.releaseOpenFailed)));
                            }
                          },
                          child: Text(s.updateReleaseLink,
                              style: const TextStyle(
                                  decoration: TextDecoration.underline))),
                    if (url != null) const SizedBox(height: 8),
                    if (checking) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(s.checkingUpdate)
                    ],
                    if (update != null || result?.version != null)
                      Text(
                          '${update?.version ?? result!.version}${update == null ? '' : ' · ${size(update.size)}'}'),
                    if (status != null) ...[
                      const SizedBox(height: 12),
                      Text(status)
                    ],
                    if (downloading || pausing || verifying || interrupted) ...[
                      const SizedBox(height: 16),
                      LinearProgressIndicator(
                          value: (downloading || pausing || interrupted) &&
                                  update != null
                              ? state.received / update.size
                              : null),
                      const SizedBox(height: 8),
                      if (update != null)
                        Text('${size(state.received)} / ${size(update.size)}'),
                      const SizedBox(height: 8),
                      if (!interrupted) Text(s.updateHiddenHint),
                    ],
                    if (error != null && error != 'paused') ...[
                      const SizedBox(height: 12),
                      Text(s.updateApkError(error))
                    ],
                    if (result?.status == UpdateStatus.available ||
                        update != null) ...[
                      const SizedBox(height: 16),
                      UpdateReleaseNotes(notes),
                    ],
                  ]))),
          actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          actions: [
            if (!state.working &&
                state.phase != ApkUpdatePhase.waitingPermission)
              Table(
                columnWidths: const {
                  0: FlexColumnWidth(),
                  1: _UpdateActionColumnWidth(),
                },
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                children: [
                  TableRow(children: [
                    if (interrupted)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                            onPressed: cubit.cancel,
                            child: Text(s.updateDownloadCancel)),
                      )
                    else
                      const SizedBox.shrink(),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: TextButton(
                        style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            minimumSize: const Size(48, 48)),
                        onPressed: () => unawaited(cubit.check(fresh: true)),
                        child: Text(s.updateCheckAgain),
                      ),
                    ),
                  ]),
                  TableRow(children: [
                    _dismissActions(context, s),
                    if (update != null)
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              minimumSize: const Size(48, 36)),
                          onPressed: () => unawaited(ready || retryInstall
                              ? cubit.install()
                              : cubit.start()),
                          child: Text(ready || retryInstall
                              ? s.installNow
                              : interrupted
                                  ? s.updateContinue
                                  : error != null
                                      ? s.retry
                                      : s.updateNow),
                        ),
                      )
                    else
                      const SizedBox.shrink(),
                  ]),
                ],
              )
            else
              _dismissActions(context, s,
                  working: downloading || pausing || verifying,
                  showPause: downloading || pausing,
                  pausing: pausing),
          ],
        );
      });

  Widget _dismissActions(BuildContext context, S s,
          {bool working = false,
          bool showPause = false,
          bool pausing = false}) =>
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        if (working)
          Flexible(
            flex: 4,
            child: TextButton(
                onPressed: cubit.cancel, child: Text(s.updateDownloadCancel)),
          ),
        if (showPause)
          Flexible(
            flex: 2,
            child: TextButton(
                onPressed: pausing ? null : cubit.pause,
                child: Text(s.updatePause)),
          ),
        Flexible(
          flex: 2,
          child: TextButton(
            style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.pop(context),
            child: Text(working ? s.updateHide : s.cancel),
          ),
        ),
      ]);
}

// Keep the right column at its natural width while reserving room for dismiss
// actions on narrow screens or when accessibility text is enlarged.
class _UpdateActionColumnWidth extends IntrinsicColumnWidth {
  const _UpdateActionColumnWidth();
  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      super
          .minIntrinsicWidth(cells, containerWidth)
          .clamp(0.0, containerWidth / 2);
  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) =>
      super
          .maxIntrinsicWidth(cells, containerWidth)
          .clamp(0.0, containerWidth / 2);
}
