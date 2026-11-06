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
      Future<void> save(bool enabled) async {
        final done = Completer<void>();
        context.read<SettingsBloc>().add(UpdateReaderVolumeKeys(enabled, done));
        try {
          await done.future;
        } catch (_) {
          if (context.mounted)
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(s.readerVolumeKeysSaveFailed)));
        }
      }

      if (inReader) {
        return ConstrainedBox(
            key: const ValueKey('reader-volume-keys'),
            constraints: const BoxConstraints(minHeight: 48),
            child: MergeSemantics(
                child: InkWell(
                    onTap: state.savingVolumeKeys
                        ? null
                        : () => save(!state.volumeKeys),
                    child: Row(children: [
                      const Icon(Icons.volume_up_outlined, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(s.readerVolumeKeys,
                              style: Theme.of(context).textTheme.bodyLarge)),
                      SizedBox(
                          width: 48,
                          height: 40,
                          child: FittedBox(
                              child: Switch(
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  value: state.volumeKeys,
                                  onChanged:
                                      state.savingVolumeKeys ? null : save))),
                    ]))));
      }
      return SwitchListTile(
          key: ValueKey(
              inReader ? 'reader-volume-keys' : 'settings-volume-keys'),
          contentPadding: inReader ? EdgeInsets.zero : null,
          secondary: const Icon(Icons.volume_up_outlined, size: 20),
          title: Text(s.readerVolumeKeys),
          subtitle: inReader ? null : Text(s.readerVolumeKeysHint),
          value: state.volumeKeys,
          onChanged: state.savingVolumeKeys ? null : save);
    });
  }
}
