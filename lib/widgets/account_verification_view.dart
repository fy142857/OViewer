import 'package:flutter/material.dart';
import '../core/constants/api_endpoints.dart';
import '../core/l10n/s.dart';
import '../core/network/automatic_login_check.dart';
import 'login_webview.dart';

/// Verification uses the existing browser while credentials stay in app fields.
class AccountVerificationView extends StatefulWidget {
  const AccountVerificationView({super.key});
  @override
  State<AccountVerificationView> createState() =>
      _AccountVerificationViewState();
}

class _AccountVerificationViewState extends State<AccountVerificationView> {
  int? _shown;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int?>(
        valueListenable: AutomaticLoginCheck.activeView,
        builder: (context, id, _) {
          if (id == null) {
            _shown = null;
            return const SizedBox.shrink();
          }
          if (_shown != id) {
            _shown = id;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _shown == id) {
                Scrollable.ensureVisible(context,
                    duration: const Duration(milliseconds: 180),
                    alignment: 0.1);
              }
            });
          }
          return Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(S.of(context).accountVerificationHint),
                  const SizedBox(height: 8),
                  SizedBox(
                      height: 360,
                      child: _VerificationBrowser(key: ValueKey(id), id: id)),
                ],
              ));
        },
      );
}

class _VerificationBrowser extends StatefulWidget {
  const _VerificationBrowser({super.key, required this.id});
  final int id;
  @override
  State<_VerificationBrowser> createState() => _VerificationBrowserState();
}

class _VerificationBrowserState extends State<_VerificationBrowser> {
  PublicLoginInspector? _inspector;
  @override
  void dispose() {
    final inspector = _inspector;
    if (inspector != null) AutomaticLoginCheck.detach(widget.id, inspector);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => AutomaticLoginCheck.interacted(widget.id),
        child: LoginWebView(
            url: Uri.parse(ApiEndpoints.loginPage),
            enabled: false,
            publicOnly: true,
            onLogin: (_) {},
            onInspectorReady: (inspector) {
              _inspector = inspector;
              AutomaticLoginCheck.attach(widget.id, inspector);
            }),
      );
}
