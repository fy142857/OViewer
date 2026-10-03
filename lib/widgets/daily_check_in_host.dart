import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import '../blocs/auth/auth_bloc.dart';
import '../blocs/auth/auth_state.dart';
import '../blocs/daily_check_in/daily_check_in_cubit.dart';
import '../core/l10n/s.dart';
import '../models/daily_check_in.dart';

/// Lives above routes, so reading and settings use the same lifecycle/session.
class DailyCheckInHost extends StatefulWidget {
  final Widget Function(GlobalKey<NavigatorState>, NavigatorObserver) builder;
  const DailyCheckInHost({super.key, required this.builder});
  @override
  State<DailyCheckInHost> createState() => _DailyCheckInHostState();
}

class _DailyCheckInHostState extends State<DailyCheckInHost>
    with WidgetsBindingObserver {
  final _navigator = GlobalKey<NavigatorState>();
  late final _observer = _DialogObserver(_queueDialog);
  DailyCheckInCubit? _cubit;
  StreamSubscription<AuthState>? _auth;
  StreamSubscription<DailyCheckInState>? _checkIn;
  DialogRoute<void>? _dialog;
  String? _dialogAccount;
  String? _dialogDay;
  bool _foreground = true;
  bool _queued = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (GetIt.I.isRegistered<DailyCheckInCubit>()) {
      final cubit = _cubit = GetIt.I<DailyCheckInCubit>();
      final auth = context.read<AuthBloc>();
      _applyAuth(auth.state);
      _auth = auth.stream.listen(_applyAuth);
      _checkIn = cubit.stream.listen((_) => _queueDialog());
      _foreground = WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      cubit.setForeground(_foreground);
      unawaited(WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
        if (mounted) {
          cubit.firstFrameReady();
          _queueDialog();
        }
      }));
    }
  }

  void _applyAuth(AuthState state) {
    _cubit?.setAccount(state.isLoggedIn ? state.profile.memberId : null);
    _queueDialog();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _cubit?.setForeground(_foreground);
    _queueDialog();
  }

  void _queueDialog() {
    if (!mounted || _queued || _cubit == null) return;
    _queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (mounted) _showPending();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _showPending() {
    final cubit = _cubit!;
    final state = cubit.state;
    final navigator = _navigator.currentState;
    if (_dialog != null &&
        (state.memberId != _dialogAccount || state.record.day != _dialogDay)) {
      if (_dialog!.isActive) navigator?.removeRoute(_dialog!);
      _dialog = null;
    }
    if (!_foreground ||
        navigator == null ||
        _dialog != null ||
        _observer.hasPopup ||
        !state.needsDialog ||
        state.record.day != checkInDay(DateTime.now())) return;
    final s = S.of(navigator.context);
    _dialogAccount = state.memberId;
    _dialogDay = state.record.day;
    final route = _dialog = DialogRoute<void>(
        context: navigator.context,
        builder: (context) => AlertDialog(
              title: Text(s.checkInSuccess),
              content: Text(state.record.rewards.isEmpty
                  ? s.checkInConfirmed
                  : state.record.rewards),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(s.confirm))
              ],
            ));
    unawaited(cubit.markNotified(state.memberId!, state.record.day));
    unawaited(navigator.push(route).whenComplete(() {
      if (identical(_dialog, route)) _dialog = null;
      _queueDialog();
    }));
  }

  @override
  Widget build(BuildContext context) => widget.builder(_navigator, _observer);
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _auth?.cancel();
    _checkIn?.cancel();
    _cubit?.setForeground(false);
    super.dispose();
  }
}

class _DialogObserver extends NavigatorObserver {
  final VoidCallback changed;
  final List<Route<dynamic>> _routes = [];
  _DialogObserver(this.changed);
  bool get hasPopup => _routes.any((r) => r is PopupRoute);
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _routes.remove(oldRoute);
    if (newRoute != null) _routes.add(newRoute);
    changed();
  }
}
