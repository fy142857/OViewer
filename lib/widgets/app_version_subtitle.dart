import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Reads the installed package once without delaying app startup.
class AppVersionSubtitle extends StatefulWidget {
  const AppVersionSubtitle({
    super.key,
    required this.description,
    required this.unavailableLabel,
  });

  final String description;
  final String unavailableLabel;

  @override
  State<AppVersionSubtitle> createState() => _AppVersionSubtitleState();
}

class _AppVersionSubtitleState extends State<AppVersionSubtitle> {
  late final Future<PackageInfo> _package = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _package,
      builder: (context, snapshot) {
        final info = snapshot.data;
        final String version;
        if (snapshot.connectionState != ConnectionState.done) {
          version = '…';
        } else if (info == null ||
            info.version.isEmpty ||
            info.buildNumber.isEmpty) {
          version = widget.unavailableLabel;
        } else {
          version = '${info.version} (${info.buildNumber})';
        }
        return Text('$version\n${widget.description}');
      },
    );
  }
}
