import 'package:flutter_bloc/flutter_bloc.dart';
import '../../repositories/auth_repository.dart';
import '../../core/constants/app_constants.dart';
import '../../core/network/native_auth_cookies.dart';
import 'auth_event.dart';
import 'auth_state.dart';

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  final AuthRepository _repository;
  int _operation = 0;
  int _session = 0;

  AuthBloc(this._repository) : super(const AuthState()) {
    on<CheckLoginStatus>(_onCheckStatus);
    on<LoginWithCookies>(_onLoginWithCookies);
    on<LoginFromWebView>(_onLoginFromWebView);
    on<LogoutRequested>(_onLogout);
  }

  bool _current(int operation, Emitter<AuthState> emit) =>
      !emit.isDone && operation == _operation;
  bool get _logoutBlocked =>
      state.status == AuthStatus.loggingOut ||
      state.status == AuthStatus.logoutFailed;
  bool _acceptLogin(int? generation) =>
      !_logoutBlocked && (generation == null || generation == _session);

  Future<void> _onCheckStatus(
      CheckLoginStatus event, Emitter<AuthState> emit) async {
    if (_logoutBlocked || state.status == AuthStatus.loading) return;
    final operation = _operation;
    try {
      final loggedIn = await _repository.isLoggedIn();
      if (!_current(operation, emit)) return;
      if (loggedIn) {
        final profile = await _repository.getUserProfile();
        if (!_current(operation, emit)) return;
        emit(AuthState(
            status: profile.isLoggedIn
                ? AuthStatus.authenticated
                : AuthStatus.unauthenticated,
            profile: profile,
            sessionGeneration: _session));
      } else {
        emit(AuthState(
            status: AuthStatus.unauthenticated, sessionGeneration: _session));
      }
    } catch (error) {
      if (!_current(operation, emit)) return;
      emit(AuthState(
          status: error is LogoutCleanupException
              ? AuthStatus.logoutFailed
              : AuthStatus.error,
          sessionGeneration: _session));
    }
  }

  Future<void> _onLoginWithCookies(
      LoginWithCookies event, Emitter<AuthState> emit) async {
    if (!_acceptLogin(event.sessionGeneration)) return;
    await _login(
        memberId: event.memberId,
        passHash: event.passHash,
        igneous: event.igneous,
        validate: true,
        emit: emit);
  }

  Future<void> _onLoginFromWebView(
      LoginFromWebView event, Emitter<AuthState> emit) async {
    if (!_acceptLogin(event.sessionGeneration)) return;
    final member = event.cookies[AppConstants.cookieIpbMemberId];
    final pass = event.cookies[AppConstants.cookieIpbPassHash];
    if (member == null || member.isEmpty || pass == null || pass.isEmpty) {
      emit(AuthState(
          status: AuthStatus.error,
          sessionGeneration: _session,
          errorMessage: 'Required cookies not found after login.'));
      return;
    }
    await _login(
        memberId: member,
        passHash: pass,
        igneous: event.cookies[AppConstants.cookieIgneous],
        validate: false,
        emit: emit);
  }

  Future<void> _login(
      {required String memberId,
      required String passHash,
      String? igneous,
      required bool validate,
      required Emitter<AuthState> emit}) async {
    final operation = ++_operation;
    emit(AuthState(status: AuthStatus.loading, sessionGeneration: _session));
    try {
      await _repository.saveLoginCookies(
          memberId: memberId, passHash: passHash, igneous: igneous);
      if (!_current(operation, emit)) return;
      if (validate && !await _repository.validateLogin()) {
        if (!_current(operation, emit)) return;
        await _repository.logout();
        if (!_current(operation, emit)) return;
        emit(AuthState(
            status: AuthStatus.error,
            sessionGeneration: _session,
            errorMessage: 'Invalid cookies. Login verification failed.'));
        return;
      }
      if (!_current(operation, emit)) return;
      final profile = await _repository.getUserProfile();
      if (!_current(operation, emit)) return;
      emit(AuthState(
          status:
              profile.isLoggedIn ? AuthStatus.authenticated : AuthStatus.error,
          profile: profile,
          sessionGeneration: _session));
    } catch (error) {
      if (!_current(operation, emit)) return;
      emit(AuthState(
          status: error is LogoutCleanupException
              ? AuthStatus.logoutFailed
              : AuthStatus.error,
          sessionGeneration: _session,
          errorMessage: 'Login could not be completed.'));
    }
  }

  Future<void> _onLogout(LogoutRequested event, Emitter<AuthState> emit) async {
    if (state.status == AuthStatus.loggingOut) return;
    final operation = ++_operation;
    _session++;
    // Immediately disables account actions and cancels daily check-in work.
    emit(AuthState(status: AuthStatus.loggingOut, sessionGeneration: _session));
    try {
      await _repository.logout();
      if (_current(operation, emit)) {
        emit(AuthState(
            status: AuthStatus.unauthenticated, sessionGeneration: _session));
      }
    } catch (_) {
      if (_current(operation, emit)) {
        emit(AuthState(
            status: AuthStatus.logoutFailed, sessionGeneration: _session));
      }
    }
  }
}
