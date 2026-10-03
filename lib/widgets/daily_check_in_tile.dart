import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/daily_check_in/daily_check_in_cubit.dart';
import '../core/l10n/s.dart';
import '../models/daily_check_in.dart';

class DailyCheckInTile extends StatefulWidget {
  final DailyCheckInCubit cubit;
  const DailyCheckInTile({super.key, required this.cubit});
  @override
  State<DailyCheckInTile> createState() => _DailyCheckInTileState();
}

class _DailyCheckInTileState extends State<DailyCheckInTile> {
  Timer? _cooldown;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _cooldown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted &&
          widget.cubit.state.record.lastAttempt != null &&
          widget.cubit.state.status != CheckInStatus.confirmed) setState(() {});
    });
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return BlocBuilder<DailyCheckInCubit, DailyCheckInState>(
        bloc: widget.cubit,
        builder: (context, state) => Column(children: [
              SwitchListTile(
                  secondary: const Icon(Icons.event_available),
                  title: Text(s.autoCheckIn),
                  subtitle: Text(s.checkInSchedule),
                  value: state.enabled,
                  onChanged: _saving || state.memberId == null
                      ? null
                      : (value) async {
                          setState(() => _saving = true);
                          await widget.cubit.setEnabled(value);
                          if (mounted) setState(() => _saving = false);
                        }),
              ListTile(
                  enabled: state.memberId != null,
                  leading: const SizedBox(width: 24, height: 24),
                  title: Text(s.dailyCheckIn),
                  subtitle: Text(state.storageFailed
                      ? s.checkInStorageError
                      : s.checkInStatus(state.status)),
                  trailing: state.status == CheckInStatus.running
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : TextButton(
                          onPressed: widget.cubit.canCheckManually
                              ? () => widget.cubit.check(manual: true)
                              : null,
                          child: Text(state.status == CheckInStatus.failed ||
                                  state.status == CheckInStatus.unconfirmed
                              ? s.retry
                              : s.checkInNow))),
            ]));
  }
}
