import 'package:equatable/equatable.dart';
import '../../models/user_profile.dart';
import '../../core/network/account_login_client.dart';

enum AuthStatus {
  unknown,
  authenticated,
  unauthenticated,
  loading,
  error,
  loggingOut,
  logoutFailed
}

class AuthState extends Equatable {
  final AuthStatus status;
  final UserProfile profile;
  final String? errorMessage;
  final int sessionGeneration;
  final AccountLoginFailure? accountFailure;
  final bool exUnavailable;

  const AuthState({
    this.status = AuthStatus.unknown,
    this.profile = const UserProfile.guest(),
    this.errorMessage,
    this.sessionGeneration = 0,
    this.accountFailure,
    this.exUnavailable = false,
  });

  bool get isLoggedIn => status == AuthStatus.authenticated;

  AuthState copyWith({
    AuthStatus? status,
    UserProfile? profile,
    String? errorMessage,
    int? sessionGeneration,
    AccountLoginFailure? accountFailure,
    bool? exUnavailable,
  }) {
    return AuthState(
      status: status ?? this.status,
      profile: profile ?? this.profile,
      errorMessage: errorMessage ?? this.errorMessage,
      sessionGeneration: sessionGeneration ?? this.sessionGeneration,
      accountFailure: accountFailure ?? this.accountFailure,
      exUnavailable: exUnavailable ?? this.exUnavailable,
    );
  }

  @override
  List<Object?> get props => [
        status,
        profile,
        errorMessage,
        sessionGeneration,
        accountFailure,
        exUnavailable
      ];
}
