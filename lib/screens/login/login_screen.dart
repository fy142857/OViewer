import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../blocs/auth/auth_bloc.dart';
import '../../blocs/auth/auth_event.dart';
import '../../blocs/auth/auth_state.dart';
import '../../core/constants/app_constants.dart';
import '../../core/l10n/s.dart';
import '../../repositories/auth_repository.dart';
import 'package:get_it/get_it.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _memberIdController = TextEditingController();
  final _passHashController = TextEditingController();
  final _igneousController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _memberIdController.dispose();
    _passHashController.dispose();
    _igneousController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return BlocConsumer<AuthBloc, AuthState>(
      listener: (context, state) {
        if (state.status == AuthStatus.authenticated) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(s.loginSuccessful),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context);
        }
        if (state.status == AuthStatus.error) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.errorMessage ?? s.loginFailed),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      },
      builder: (context, state) {
        if (state.isLoggedIn) {
          return _buildLoggedInView(context, state);
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(s.login),
            bottom: TabBar(
              controller: _tabController,
              tabs: [
                Tab(text: s.webViewLogin),
                Tab(text: s.manualCookie),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tabController,
            children: [
              _buildWebViewLogin(context, state),
              _buildManualLogin(context, state),
            ],
          ),
        );
      },
    );
  }

  // ---- Logged In View ----
  Widget _buildLoggedInView(BuildContext context, AuthState state) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.account)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                child: Icon(
                  Icons.person,
                  size: 40,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                s.loggedIn,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 4),
              Text(
                s.memberId(state.profile.memberId ?? "Unknown"),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
              const SizedBox(height: 32),
              OutlinedButton.icon(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: Text(s.logout),
                      content: Text(s.logoutConfirm),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: Text(s.cancel),
                        ),
                        TextButton(
                          onPressed: () {
                            context.read<AuthBloc>().add(LogoutRequested());
                            Navigator.pop(ctx);
                          },
                          child: Text(s.logout),
                        ),
                      ],
                    ),
                  );
                },
                icon: const Icon(Icons.logout),
                label: Text(s.logout),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---- WebView Login ----
  Widget _buildWebViewLogin(BuildContext context, AuthState state) {
    if (state.status == AuthStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final loginUrl = GetIt.I<AuthRepository>().loginPageUrl;

    return InAppWebView(
      initialUrlRequest: URLRequest(url: Uri.parse(loginUrl)),
      initialOptions: InAppWebViewGroupOptions(
        crossPlatform: InAppWebViewOptions(
          javaScriptEnabled: true,
          useShouldOverrideUrlLoading: true,
        ),
      ),
      onLoadStop: (controller, url) async {
        // Check if we're on the main site after login
        final currentUrl = url?.toString() ?? '';
        if (currentUrl.contains('e-hentai.org') &&
            !currentUrl.contains('act=Login')) {
          // Try to extract cookies
          final cookies = await CookieManager.instance()
              .getCookies(url: Uri.parse(AppConstants.ehBaseUrl));

          final cookieMap = <String, String>{};
          for (final cookie in cookies) {
            cookieMap[cookie.name] = cookie.value;
          }

          // Check for required cookies
          if (cookieMap.containsKey(AppConstants.cookieIpbMemberId) &&
              cookieMap.containsKey(AppConstants.cookieIpbPassHash)) {
            if (mounted) {
              context.read<AuthBloc>().add(LoginFromWebView(cookieMap));
            }
          }
        }
      },
    );
  }

  // ---- Manual Cookie Login ----
  Widget _buildManualLogin(BuildContext context, AuthState state) {
    final s = S.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.info_outline,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(s.howToGetCookies,
                          style: Theme.of(context).textTheme.titleSmall),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    s.cookieInstructions,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _memberIdController,
            decoration: const InputDecoration(
              labelText: 'ipb_member_id *',
              hintText: 'e.g., 1234567',
              prefixIcon: Icon(Icons.badge),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _passHashController,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'ipb_pass_hash *',
              hintText: 'e.g., abcdef1234567890...',
              prefixIcon: Icon(Icons.key),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _igneousController,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: s.igneousOptional,
              hintText: 'e.g., abcdef1234...',
              prefixIcon: const Icon(Icons.vpn_key),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: state.status == AuthStatus.loading
                ? null
                : () {
                    final memberId = _memberIdController.text.trim();
                    final passHash = _passHashController.text.trim();
                    final igneous = _igneousController.text.trim();

                    if (memberId.isEmpty || passHash.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(s.memberIdPassHashRequired),
                        ),
                      );
                      return;
                    }

                    context.read<AuthBloc>().add(LoginWithCookies(
                          memberId: memberId,
                          passHash: passHash,
                          igneous: igneous.isNotEmpty ? igneous : null,
                        ));
                  },
            child: state.status == AuthStatus.loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(s.login),
          ),
        ],
      ),
    );
  }
}
