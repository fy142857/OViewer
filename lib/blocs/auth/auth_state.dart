import 'package:equatable/equatable.dart';
import '../../models/user_profile.dart';

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

  const AuthState({
    this.status = AuthStatus.unknown,
    this.profile = const UserProfile.guest(),
    this.errorMessage,
    this.sessionGeneration = 0,
  });

  bool get isLoggedIn => status == AuthStatus.authenticated;

  AuthState copyWith({
    AuthStatus? status,
    UserProfile? profile,
    String? errorMessage,
    int? sessionGeneration,
  }) {
    return AuthState(
      status: status ?? this.status,
      profile: profile ?? this.profile,
      errorMessage: errorMessage ?? this.errorMessage,
      sessionGeneration: sessionGeneration ?? this.sessionGeneration,
    );
  }

  @override
  List<Object?> get props => [status, profile, errorMessage, sessionGeneration];
}
