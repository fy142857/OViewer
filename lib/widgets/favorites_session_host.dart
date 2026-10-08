import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../blocs/auth/auth_bloc.dart';
import '../blocs/auth/auth_state.dart';
import '../blocs/settings/settings_bloc.dart';
import '../blocs/settings/settings_state.dart';
import '../blocs/favorites/favorites_bloc.dart';

class FavoritesSessionHost extends StatefulWidget {
  final Widget child;
  const FavoritesSessionHost({super.key, required this.child});
  @override
  State<FavoritesSessionHost> createState() => _FavoritesSessionHostState();
}

class _FavoritesSessionHostState extends State<FavoritesSessionHost> {
  void _sync() {
    final auth = context.read<AuthBloc>().state;
    final settings = context.read<SettingsBloc>().state;
    context.read<FavoritesBloc>().syncSession(
        site: settings.useExHentai
            ? 'https://exhentai.org'
            : 'https://e-hentai.org',
        signedIn: auth.isLoggedIn,
        revision: auth.sessionGeneration,
        account: auth.profile.memberId);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  Widget build(BuildContext context) => MultiBlocListener(listeners: [
        BlocListener<AuthBloc, AuthState>(listener: (_, __) => _sync()),
        BlocListener<SettingsBloc, SettingsState>(
            listenWhen: (a, b) => a.useExHentai != b.useExHentai,
            listener: (_, __) => _sync()),
      ], child: widget.child);
}
