import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/settings/settings_bloc.dart';
import '../core/l10n/s.dart';
import '../core/router/route_observer.dart';
import '../core/services/sponsor_service.dart';

class SponsorPanel extends StatefulWidget {
  final SponsorService? service;
  const SponsorPanel({super.key, this.service});
  @override
  State<SponsorPanel> createState() => _SponsorPanelState();
}

class _SponsorPanelState extends State<SponsorPanel>
    with WidgetsBindingObserver, RouteAware {
  late final SponsorService _service = widget.service ?? SponsorService();
  final _saving = <SponsorPlatform>{};
  final _opening = <SponsorPlatform>{};
  final _messages = <String>[];
  AppLifecycleState? _lifecycle;
  bool _notificationHintShown = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = WidgetsBinding.instance.lifecycleState;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) appRouteObserver.subscribe(this, route);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    if (state == AppLifecycleState.resumed) _flush();
  }

  @override
  void didPopNext() => _flush();
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    appRouteObserver.unsubscribe(this);
    super.dispose();
  }

  void _message(String message) {
    if (!mounted) return;
    _messages.add(message);
    _flush();
  }

  void _flush() {
    if (!mounted ||
        (_lifecycle != null && _lifecycle != AppLifecycleState.resumed)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          ModalRoute.of(context)?.isCurrent == false ||
          (_lifecycle != null && _lifecycle != AppLifecycleState.resumed))
        return;
      for (final message in _messages) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
      _messages.clear();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _start(SponsorPlatform platform) {
    if (_saving.contains(platform) || _opening.contains(platform)) return;
    final s = S.of(context);
    setState(() {
      _saving.add(platform);
      _opening.add(platform);
    });
    // Permission, saving and launching do not wait for each other.
    unawaited(_prepareNotifications(s));
    unawaited(_save(platform, s));
    unawaited(_open(platform, s));
  }

  Future<void> _prepareNotifications(S s) async {
    final allowed = await _service.prepareNotifications();
    if (!allowed && mounted && !_notificationHintShown) {
      _notificationHintShown = true;
      _message(s.sponsorNotificationsDisabled);
    }
  }

  Future<void> _save(SponsorPlatform platform, S s) async {
    try {
      await _service.saveCode(platform,
          notificationBody: s.sponsorSaved(platform == SponsorPlatform.wechat));
    } catch (error) {
      _message(error is PlatformException && error.code == 'permission_denied'
          ? s.sponsorPhotoPermission
          : s.sponsorSaveFailed(platform == SponsorPlatform.wechat));
    } finally {
      if (mounted) setState(() => _saving.remove(platform));
    }
  }

  Future<void> _open(SponsorPlatform platform, S s) async {
    try {
      if (!await _service.openApp(platform))
        _message(s.sponsorOpenFailed(platform == SponsorPlatform.wechat));
    } catch (_) {
      _message(s.sponsorOpenFailed(platform == SponsorPlatform.wechat));
    } finally {
      if (mounted) setState(() => _opening.remove(platform));
    }
  }

  @override
  Widget build(BuildContext context) {
    context.select((SettingsBloc bloc) => bloc.state.locale);
    final s = S.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Column(children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final platform in SponsorPlatform.values) ...[
              if (platform == SponsorPlatform.alipay) const SizedBox(width: 16),
              Expanded(
                  child: Column(children: [
                AspectRatio(
                    key: ValueKey('sponsor-code-${platform.name}'),
                    aspectRatio: 1,
                    child: ColoredBox(
                        color: Colors.white,
                        child: Image.asset(platform.asset,
                            fit: BoxFit.contain,
                            semanticLabel: s.sponsorCode(
                                platform == SponsorPlatform.wechat)))),
                TextButton(
                    key: ValueKey('sponsor-action-${platform.name}'),
                    onPressed: _saving.contains(platform) ||
                            _opening.contains(platform)
                        ? null
                        : () => _start(platform),
                    child: Text(
                        platform == SponsorPlatform.wechat
                            ? s.sponsorWechatAction
                            : s.sponsorAlipayAction,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: platform == SponsorPlatform.wechat
                                ? (dark
                                    ? const Color(0xFF81C784)
                                    : const Color(0xFF2E7D32))
                                : (dark
                                    ? const Color(0xFF64B5F6)
                                    : const Color(0xFF1565C0))))),
              ])),
            ],
          ]),
          const SizedBox(height: 8),
          Text(s.sponsorMessage,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium),
        ]));
  }
}
