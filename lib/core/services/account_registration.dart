import 'package:flutter/services.dart';

class AccountRegistration {
  static const _channel = MethodChannel('oviewer/account_registration');
  static Future<bool> open() async {
    try {
      return await _channel.invokeMethod<bool>('open') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
