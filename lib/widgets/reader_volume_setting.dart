import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/settings/settings_bloc.dart';
import '../blocs/settings/settings_event.dart';
import '../blocs/settings/settings_state.dart';
import '../core/l10n/s.dart';
import '../core/services/reader_volume_keys.dart';

class ReaderVolumeSetting extends StatelessWidget {
  final bool inReader;
  const ReaderVolumeSetting({super.key, this.inReader = false});
  @override
  Widget build(BuildContext context) {
    if (!ReaderVolumeKeys.supported) return const SizedBox.shrink();
    return BlocBuilder<SettingsBloc, SettingsState>(builder: (context, state) {
      final s = S.of(context);
      return SwitchListTile(
          key: ValueKey(
              inReader ? 'reader-volume-keys' : 'settings-volume-keys'),
          contentPadding: inReader ? EdgeInsets.zero : null,
          secondary: const Icon(Icons.volume_up_outlined, size: 20),
          title: Text(s.readerVolumeKeys),
          subtitle: inReader ? null : Text(s.readerVolumeKeysHint),
          value: state.volumeKeys,
          onChanged: state.savingVolumeKeys
              ? null
              : (enabled) async {
                  final done = Completer<void>();
                  context
                      .read<SettingsBloc>()
                      .add(UpdateReaderVolumeKeys(enabled, done));
                  try {
                    await done.future;
                  } catch (_) {
                    if (context.mounted)
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(s.readerVolumeKeysSaveFailed)));
                  }
                });
    });
  }
}
