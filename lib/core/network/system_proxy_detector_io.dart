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
      _log.i('System proxy from env: $envProxy');
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
      final interfaces = await NetworkInterface.list();
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

  static Future<String?> probeLocalProxy() async {
    final hosts = <String>['127.0.0.1'];
    // Android Emulator maps 10.0.2.2 to the host computer. A Flutter process
    // inside the emulator cannot reach the desktop proxy via 127.0.0.1.
    if (Platform.isAndroid) hosts.add('10.0.2.2');

    for (final host in hosts) {
      for (final port in _commonPorts) {
        try {
          final socket = await Socket.connect(
            host,
            port,
            timeout: const Duration(milliseconds: 500),
          );
          socket.destroy();
          final url = 'http://$host:$port';
          _log.i('Local proxy port open: $url');
          return url;
        } catch (e) {
          _log.d('Proxy $host:$port not open: $e');
        }
      }
    }
    return null;
  }

  static Future<AutoProxyResult> detect() async {
    final envProxy = detectEnvProxy();
    if (envProxy != null) {
      return AutoProxyResult(proxyUrl: envProxy, vpnActive: false);
    }
    final vpn = await isVpnActive();
    if (vpn) {
      return AutoProxyResult(
        proxyUrl: await probeLocalProxy(),
        vpnActive: true,
      );
    }
    return const AutoProxyResult(proxyUrl: null, vpnActive: false);
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
