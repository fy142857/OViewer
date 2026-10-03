import 'package:equatable/equatable.dart';

abstract class AuthEvent extends Equatable {
  const AuthEvent();
  @override
  List<Object?> get props => [];
}

class CheckLoginStatus extends AuthEvent {}

class LoginWithCookies extends AuthEvent {
  final String memberId;
  final String passHash;
  final String? igneous;
  final int? sessionGeneration;
  const LoginWithCookies({
    required this.memberId,
    required this.passHash,
    this.igneous,
    this.sessionGeneration,
  });
  @override
  List<Object?> get props => [memberId, passHash, igneous, sessionGeneration];
}

class LoginFromWebView extends AuthEvent {
  final Map<String, String> cookies;
  final int? sessionGeneration;
  const LoginFromWebView(this.cookies, {this.sessionGeneration});
  @override
  List<Object?> get props => [cookies, sessionGeneration];
}

class LogoutRequested extends AuthEvent {}
