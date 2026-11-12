import 'dart:async';
import 'package:flutter/services.dart';

class UploadNavigation {
  static const channel = MethodChannel('oviewer/upload_navigation');
  Future<void>? _ready;
  void Function()? _open;
  bool _pending = false;

  void attach(void Function() open) {
    _open = open;
    _ready ??= _initialize();
    _drain();
  }

  Future<void> _initialize() async {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'open') {
        _pending = true;
        _drain();
      }
    });
    try {
      _pending = await channel.invokeMethod<bool>('ready') == true || _pending;
      _drain();
    } on MissingPluginException {
      // Desktop widget tests do not have a native upload notification surface.
    }
  }

  void _drain() {
    if (_pending && _open != null) {
      _pending = false;
      _open!();
    }
  }

  void dispose() {
    _open = null;
    channel.setMethodCallHandler(null);
  }
}
