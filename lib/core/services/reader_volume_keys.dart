import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import '../router/route_observer.dart';

/// Only the foremost, resumed reader owns Android's hardware volume keys.
class ReaderVolumeKeys extends StatefulWidget {
  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  static const channel = MethodChannel('oviewer/reader_volume_keys');
  final bool enabled;
  final ValueChanged<int> onTurn;
  final Widget child;
  const ReaderVolumeKeys(
      {super.key,
      required this.enabled,
      required this.onTurn,
      required this.child});
  @override
  State<ReaderVolumeKeys> createState() => _ReaderVolumeKeysState();
}

class _ReaderVolumeKeysState extends State<ReaderVolumeKeys>
    with WidgetsBindingObserver, RouteAware {
  static final _owners = <_ReaderVolumeKeysState>[];
  ModalRoute<dynamic>? _route;
  bool _resumed = true;
  bool _covered = false;
  bool get _active =>
      mounted &&
      widget.enabled &&
      _resumed &&
      !_covered &&
      (_route?.isCurrent ?? false);

  static void _sync() {
    final owner = _owners.isEmpty ? null : _owners.last;
    if (!ReaderVolumeKeys.supported) return;
    unawaited(ReaderVolumeKeys.channel
        .invokeMethod<void>('setEnabled', owner?._active ?? false)
        .catchError((Object _) {}));
  }

  @override
  void initState() {
    super.initState();
    _resumed = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    if (_owners.isEmpty) {
      ReaderVolumeKeys.channel.setMethodCallHandler((call) async {
        if (call.method != 'turn' || _owners.isEmpty) return;
        final owner = _owners.last;
        final delta = call.arguments;
        if (owner._active && (delta == -1 || delta == 1))
          owner.widget.onTurn(delta as int);
      });
    }
    _owners.add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route != route) {
      appRouteObserver.unsubscribe(this);
      _route = route;
      if (route != null) appRouteObserver.subscribe(this, route);
    }
    _sync();
  }

  @override
  void didUpdateWidget(ReaderVolumeKeys oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void didPushNext() {
    _covered = true;
    _sync();
  }

  @override
  void didPopNext() {
    _covered = false;
    _sync();
  }

  @override
  void didPop() {
    _covered = true;
    _sync();
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _owners.remove(this);
    _sync();
    if (_owners.isEmpty) ReaderVolumeKeys.channel.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
