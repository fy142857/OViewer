import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get_it/get_it.dart';

import '../core/l10n/s.dart';
import '../core/network/cookie_manager.dart' as app;
import 'error_widget.dart';

/// A settings page must receive the selected site's login cookies before its
/// first request, including when login was performed by entering cookies.
class SiteSettingsWebView extends StatefulWidget {
  final Uri url;

  const SiteSettingsWebView({super.key, required this.url});

  @override
  State<SiteSettingsWebView> createState() => _SiteSettingsWebViewState();
}

class _SiteSettingsWebViewState extends State<SiteSettingsWebView> {
  late Future<void> _sessionReady;

  @override
  void initState() {
    super.initState();
    _prepareSession();
  }

  @override
  void didUpdateWidget(SiteSettingsWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _prepareSession();
  }

  void _prepareSession() {
    _sessionReady = GetIt.I<app.CookieManager>().syncToWebView(widget.url);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _sessionReady,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return AppErrorWidget(
            message: S.of(context).loadFailedTapRetry,
            onRetry: () => setState(_prepareSession),
          );
        }
        return InAppWebView(
          key: ValueKey(widget.url),
          initialUrlRequest: URLRequest(url: widget.url),
          initialOptions: InAppWebViewGroupOptions(
            crossPlatform: InAppWebViewOptions(javaScriptEnabled: true),
          ),
        );
      },
    );
  }
}
