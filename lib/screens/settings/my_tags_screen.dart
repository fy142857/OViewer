import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../blocs/settings/settings_bloc.dart';
import '../../blocs/settings/settings_event.dart';
import '../../core/constants/api_endpoints.dart';
import '../../core/l10n/s.dart';
import '../../widgets/site_settings_webview.dart';

class MyTagsScreen extends StatefulWidget {
  const MyTagsScreen({super.key});

  @override
  State<MyTagsScreen> createState() => _MyTagsScreenState();
}

class _MyTagsScreenState extends State<MyTagsScreen> {
  void _syncTags() {
    context.read<SettingsBloc>().add(SyncMyTags());
  }

  @override
  Widget build(BuildContext context) {
    // ignore: deprecated_member_use
    return WillPopScope(
      onWillPop: () async {
        _syncTags();
        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(S.of(context).myTags),
        ),
        body: SiteSettingsWebView(url: Uri.parse(ApiEndpoints.myTags)),
      ),
    );
  }
}
