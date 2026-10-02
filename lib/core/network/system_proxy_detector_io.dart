import 'dart:io';
import 'package:logger/logger.dart';

class SystemProxyDetector {
  static final _log = Logger();

  static const List<int> _commonPorts = [
    7890,
    7891,
    7897,
    1080,
    1081,
    8080,
    8118,
    10808,
    10809,
  ];

  static String? detectEnvProxy() {
    final envProxy = Platform.environment['http_proxy'] ??
        Platform.environment['HTTP_PROXY'] ??
        Platform.environment['https_proxy'] ??
        Platform.environment['HTTPS_PROXY'];
    if (envProxy != null && envProxy.isNotEmpty) {
      _log.i('Environment proxy detected');
      return _normalize(envProxy);
    }

    try {
      final proxyStr = HttpClient.findProxyFromEnvironment(
        Uri.parse('https://e-hentai.org'),
      );
      if (proxyStr != 'DIRECT' && proxyStr.startsWith('PROXY ')) {
        final hostPort = proxyStr.substring(6).trim();
        if (hostPort.isNotEmpty) return 'http://$hostPort';
      }
    } catch (e) {
      _log.w('Failed to detect platform proxy: $e');
    }
    return null;
  }

  static Future<bool> isVpnActive() async {
    try {
      final interfaces = await NetworkInterface.list()
          .timeout(const Duration(milliseconds: 500));
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.startsWith('tun') ||
            name.startsWith('ppp') ||
            name.startsWith('tap') ||
            name.startsWith('utun')) {
          return true;
        }
      }
    } catch (e) {
      _log.w('Failed to check VPN status: $e');
    }
    return false;
  }

  static Future<bool> _connect(String host, int port) async {
    final socket = await Socket.connect(host, port,
        timeout: const Duration(milliseconds: 500));
    socket.destroy();
    return true;
  }

  static Future<String?> probeLocalProxy(
      {List<String>? hosts,
      List<int>? ports,
      Future<bool> Function(String, int)? probe}) async {
    final targets = hosts ?? ['127.0.0.1', if (Platform.isAndroid) '10.0.2.2'];
    final candidates = ports ?? _commonPorts;
    for (final host in targets) {
      final open = await Future.wait(candidates.map((port) async {
        try {
          return await (probe ?? _connect)(host, port)
              .timeout(const Duration(milliseconds: 500));
        } catch (_) {
          return false;
        }
      }));
      for (var i = 0; i < open.length; i++) {
        if (open[i]) return 'http://$host:${candidates[i]}';
      }
    }
    return null;
  }

  static Future<AutoProxyResult> detect(
      {String? Function()? environmentProxy,
      Future<bool> Function()? vpnCheck,
      Future<String?> Function()? localProbe}) async {
    final envProxy = (environmentProxy ?? detectEnvProxy)();
    if (envProxy != null) {
      return AutoProxyResult(proxyUrl: envProxy, vpnActive: false);
    }
    var vpn = false;
    try {
      vpn = await (vpnCheck ?? isVpnActive)()
          .timeout(const Duration(milliseconds: 500));
    } catch (_) {/* Interface failures keep the existing direct fallback. */}
    return AutoProxyResult(
      proxyUrl: vpn ? await (localProbe ?? probeLocalProxy)() : null,
      vpnActive: vpn,
    );
  }

  static String _normalize(String proxy) {
    final trimmed = proxy.trim();
    if (trimmed.startsWith('http://') ||
        trimmed.startsWith('https://') ||
        trimmed.startsWith('socks5://')) {
      return trimmed;
    }
    return 'http://$trimmed';
  }
}

class AutoProxyResult {
  final String? proxyUrl;
  final bool vpnActive;

  const AutoProxyResult({required this.proxyUrl, required this.vpnActive});
}
