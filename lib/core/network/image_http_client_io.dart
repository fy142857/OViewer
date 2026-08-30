import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'network_proxy_io.dart';

/// Proxy lookup is evaluated for each request, so settings changes apply
/// without recreating the image cache manager.
http.Client createImageHttpClient() =>
    IOClient(NetworkProxy.createHttpClient());
