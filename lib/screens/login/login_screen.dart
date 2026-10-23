import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../blocs/auth/auth_bloc.dart';
import '../../blocs/auth/auth_event.dart';
import '../../blocs/auth/auth_state.dart';
import '../../widgets/login_webview.dart';
import '../../core/l10n/s.dart';
import '../../repositories/auth_repository.dart';
import 'package:get_it/get_it.dart';
import 'package:dio/dio.dart';
import '../../core/network/account_login_client.dart';
import '../../core/services/account_registration.dart';
import '../../widgets/account_verification_view.dart';

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
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  AuthBloc? _auth;
  CancelToken? _accountRequest;
  int _selectedTab = 0;
  bool _webViewOpened = false;
  bool _showPassword = false;
  bool _openingRegistration = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this)
      ..addListener(_tabChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _auth = context.read<AuthBloc>();
  }

  void _tabChanged() {
    if (_selectedTab == _tabController.index) return;
    if (_selectedTab == 0) {
      _passwordController.clear();
      _cancelAccount();
    }
    setState(() {
      _selectedTab = _tabController.index;
      if (_selectedTab == 1) _webViewOpened = true;
      _showPassword = false;
    });
  }

  @override
  void dispose() {
    _cancelAccount();
    _tabController.removeListener(_tabChanged);
    _tabController.dispose();
    _memberIdController.dispose();
    _passHashController.dispose();
    _igneousController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _cancelAccount() {
    _accountRequest?.cancel();
    _accountRequest = null;
    _auth?.cancelAccountLogin();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return BlocConsumer<AuthBloc, AuthState>(
      listener: (context, state) {
        if (state.status != AuthStatus.loading) _accountRequest = null;
        if (state.status == AuthStatus.authenticated) {
          _passwordController.clear();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.exUnavailable
                  ? s.exLoginUnavailable
                  : s.loginSuccessful),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context);
        }
        if (state.status == AuthStatus.error && state.accountFailure == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.errorMessage ?? s.loginFailed),
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          );
        }
      },
      builder: (context, state) {
        if (state.status == AuthStatus.unknown ||
            state.status == AuthStatus.loggingOut ||
            state.status == AuthStatus.logoutFailed) {
          return Scaffold(
              appBar: AppBar(title: Text(s.account)),
              body: Center(
                  child: state.status == AuthStatus.logoutFailed
                      ? Column(mainAxisSize: MainAxisSize.min, children: [
                          Padding(
                              padding: const EdgeInsets.all(24),
                              child: Text(s.logoutCleanupFailed)),
                          TextButton(
                              onPressed: () => context
                                  .read<AuthBloc>()
                                  .add(LogoutRequested()),
                              child: Text(s.retry)),
                        ])
                      : Column(mainAxisSize: MainAxisSize.min, children: [
                          const CircularProgressIndicator(),
                          if (state.status == AuthStatus.loggingOut)
                            Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(s.loggingOut)),
                        ])));
        }
        if (state.isLoggedIn) {
          return _buildLoggedInView(context, state);
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(s.login),
            bottom: TabBar(
              controller: _tabController,
              tabs: [
                Tab(text: s.accountLogin),
                Tab(text: s.webViewLogin),
                Tab(text: s.manualCookie),
              ],
            ),
          ),
          body: TabBarView(
            controller: _tabController,
            children: [
              _buildAccountLogin(context, state),
              _webViewOpened
                  ? _buildWebViewLogin(context, state)
                  : const SizedBox.shrink(),
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
    final loginUrl = GetIt.I<AuthRepository>().loginPageUrl;
    return Stack(
      children: [
        LoginWebView(
          key: ValueKey(state.sessionGeneration),
          url: Uri.parse(loginUrl),
          enabled: _selectedTab == 1 && state.status != AuthStatus.loading,
          onLogin: (cookies) {
            if (_selectedTab != 1) return;
            context.read<AuthBloc>().add(LoginFromWebView(cookies,
                sessionGeneration: state.sessionGeneration));
          },
        ),
        if (state.status == AuthStatus.loading)
          const Positioned.fill(
            child: AbsorbPointer(
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }

  // ---- Manual Cookie Login ----
  Widget _buildAccountLogin(BuildContext context, AuthState state) {
    final s = S.of(context);
    final loading = state.status == AuthStatus.loading;
    void submit() {
      if (loading || _accountRequest != null) return;
      if (_usernameController.text.trim().isEmpty ||
          _passwordController.text.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(s.accountRequired)));
        return;
      }
      FocusScope.of(context).unfocus();
      _accountRequest = CancelToken();
      context.read<AuthBloc>().add(LoginWithAccount(
          username: _usernameController.text.trim(),
          password: _passwordController.text,
          sessionGeneration: state.sessionGeneration,
          cancelToken: _accountRequest));
    }

    final error = switch (state.accountFailure) {
      AccountLoginFailure.credentials => s.accountInvalid,
      AccountLoginFailure.challenge => s.accountChallenge,
      AccountLoginFailure.browserRequired => s.accountBrowserRequired,
      AccountLoginFailure.network => s.accountNetworkError,
      AccountLoginFailure.site => s.accountSiteError,
      null => null,
    };
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
            controller: _usernameController,
            enabled: !loading,
            keyboardType: TextInputType.text,
            autocorrect: false,
            // Android maps disabled suggestions to a password input variation.
            enableSuggestions: true,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
                labelText: s.username,
                prefixIcon: const Icon(Icons.person_outline))),
        const SizedBox(height: 16),
        TextField(
            controller: _passwordController,
            enabled: !loading,
            obscureText: !_showPassword,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => submit(),
            decoration: InputDecoration(
                labelText: s.password,
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                    tooltip: _showPassword ? s.hidePassword : s.showPassword,
                    onPressed: () =>
                        setState(() => _showPassword = !_showPassword),
                    icon: Icon(_showPassword
                        ? Icons.visibility_off
                        : Icons.visibility)))),
        const AccountVerificationView(),
        if (error != null) ...[
          const SizedBox(height: 16),
          if (state.accountFailure == AccountLoginFailure.challenge ||
              state.accountFailure == AccountLoginFailure.browserRequired)
            TextButton(
                onPressed: () => _tabController.animateTo(1),
                child: Text(error))
          else
            Text(error,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 24),
        if (loading)
          Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(s.accountLoginWaiting, textAlign: TextAlign.center)),
        FilledButton(
            onPressed: loading ? null : submit,
            child: loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Text(s.login)),
        const SizedBox(height: 8),
        TextButton(
            onPressed: loading || _openingRegistration
                ? null
                : () async {
                    setState(() => _openingRegistration = true);
                    final opened = await AccountRegistration.open();
                    if (!mounted) return;
                    setState(() => _openingRegistration = false);
                    if (!opened)
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(s.registrationOpenFailed)));
                  },
            child: Text(s.registerAccount)),
      ]),
    );
  }

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
                          sessionGeneration: state.sessionGeneration,
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
