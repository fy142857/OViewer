import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/settings/settings_bloc.dart';
import '../blocs/settings/settings_event.dart';
import '../blocs/settings/settings_state.dart';
import '../core/l10n/s.dart';
import '../models/floating_back_settings.dart';
import 'floating_back_host.dart';

class FloatingBackSetting extends StatefulWidget {
  const FloatingBackSetting({super.key});
  @override
  State<FloatingBackSetting> createState() => _FloatingBackSettingState();
}

class _FloatingBackSettingState extends State<FloatingBackSetting> {
  double? _previewSize;
  bool _saving = false;
  FloatingBackPreview? _preview;

  Future<void> _save({bool? enabled, double? size}) async {
    setState(() => _saving = true);
    final done = Completer<void>();
    context
        .read<SettingsBloc>()
        .add(UpdateFloatingBack(done, enabled: enabled, size: size));
    try {
      await done.future;
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(S.of(context).floatingBackSaveFailed)));
    } finally {
      _preview?.clear(this);
      if (mounted)
        setState(() {
          _previewSize = null;
          _saving = false;
        });
    }
  }

  @override
  void dispose() {
    final preview = _preview;
    WidgetsBinding.instance.addPostFrameCallback((_) => preview?.clear(this));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      BlocSelector<SettingsBloc, SettingsState, FloatingBackSettings>(
          selector: (state) => state.floatingBack,
          builder: (context, value) {
            _preview = FloatingBackScope.maybeOf(context);
            final s = S.of(context);
            final size = _previewSize ?? value.size;
            return Column(children: [
              SwitchListTile(
                  key: const ValueKey('settings-floating-back'),
                  secondary: const Icon(Icons.arrow_circle_left_outlined),
                  title: Text(s.floatingBack),
                  subtitle: Text(s.floatingBackHint),
                  value: value.enabled,
                  onChanged:
                      _saving ? null : (enabled) => _save(enabled: enabled)),
              Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${s.floatingBackSize} · ${size.round()}'),
                        Slider(
                            key: const ValueKey('floating-back-size'),
                            value: size,
                            min: FloatingBackSettings.minSize,
                            max: FloatingBackSettings.maxSize,
                            label: '${size.round()}',
                            semanticFormatterCallback: (value) =>
                                '${value.round()}',
                            onChanged: !value.enabled || _saving
                                ? null
                                : (size) {
                                    setState(() => _previewSize = size);
                                    _preview?.set(this, size);
                                  },
                            onChangeEnd: !value.enabled || _saving
                                ? null
                                : (size) => _save(size: size)),
                      ])),
            ]);
          });
}
