import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class FloatingBackKeyboard {
  static const channel = MethodChannel('oviewer/floating_back');

  static Future<void> hide() async {
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      // Also dismisses native WebView inputs inside the application's window.
      await channel.invokeMethod<void>('hideKeyboard');
    } on MissingPluginException {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } on PlatformException {
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }
  }
}
