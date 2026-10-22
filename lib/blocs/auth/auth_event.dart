import 'package:equatable/equatable.dart';
import 'package:dio/dio.dart';

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

class LoginWithAccount extends AuthEvent {
  const LoginWithAccount(
      {required this.username,
      required this.password,
      required this.sessionGeneration,
      this.cancelToken});
  final String username;
  final String password;
  final int sessionGeneration;
  final CancelToken? cancelToken;
  // Equatable/event observers must not stringify credentials.
  @override
  String toString() => 'LoginWithAccount';
}

class CancelAccountLogin extends AuthEvent {
  const CancelAccountLogin(this.operation);
  final int operation;
  @override
  List<Object?> get props => [operation];
}
