import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/update/update_cubit.dart';
import '../core/l10n/s.dart';
import '../repositories/update_repository.dart';

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
        final verifying = state.phase == ApkUpdatePhase.verifying;
        final checking = state.phase == ApkUpdatePhase.checking;
        final ready = state.phase == ApkUpdatePhase.ready;
        final error = state.error ?? result?.apkFailure;
        final url = update?.releaseUrl ?? result?.releaseUrl;
        final notes = update?.notes ?? result?.notes ?? '';
        String? status;
        if (ready) status = s.updateReady;
        if (state.phase == ApkUpdatePhase.waitingPermission)
          status = s.updatePermission;
        if (result?.status == UpdateStatus.current) status = s.versionCurrent;
        if (result?.status == UpdateStatus.ahead) status = s.versionAhead;
        if (result?.status == UpdateStatus.noRelease)
          status = s.noReleaseAvailable;
        final retryInstall = state.path != null &&
            const ['permission', 'no_installer', 'unavailable'].contains(error);
        return AlertDialog(
          title: Text(downloading
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
                    if (downloading || verifying) ...[
                      const SizedBox(height: 16),
                      LinearProgressIndicator(
                          value: downloading && update != null
                              ? state.received / update.size
                              : null),
                      const SizedBox(height: 8),
                      if (update != null)
                        Text('${size(state.received)} / ${size(update.size)}'),
                      const SizedBox(height: 8),
                      Text(s.updateHiddenHint),
                    ],
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Text(s.updateApkError(error))
                    ],
                    if (result?.status == UpdateStatus.available ||
                        update != null) ...[
                      const SizedBox(height: 16),
                      Text(notes.isEmpty ? s.updateNoNotes : notes),
                    ],
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
                  ]))),
          actions: [
            if (downloading || verifying)
              TextButton(
                  onPressed: cubit.cancel, child: Text(s.updateDownloadCancel)),
            if (!state.working &&
                state.phase != ApkUpdatePhase.waitingPermission)
              TextButton(
                  onPressed: () => unawaited(cubit.check(fresh: true)),
                  child: Text(s.updateCheckAgain)),
            TextButton(
                onPressed: () => Navigator.pop(context),
                child:
                    Text(downloading || verifying ? s.updateHide : s.cancel)),
            if (update != null &&
                !state.working &&
                state.phase != ApkUpdatePhase.waitingPermission)
              FilledButton(
                  onPressed: () => unawaited(
                      ready || retryInstall ? cubit.install() : cubit.start()),
                  child: Text(ready || retryInstall
                      ? s.installNow
                      : error != null
                          ? s.retry
                          : s.updateNow)),
          ],
        );
      });
}
