import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_event.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/core/network/account_login_client.dart';
import 'package:oviewer/repositories/auth_repository.dart';

class Repo extends Mock implements AuthRepository {}

const account = AccountLoginResult('123', 'test-pass', exUnavailable: true);
const event = LoginWithAccount(
    username: 'test', password: 'secret', sessionGeneration: 0);
Future<void> drain() => Future<void>.delayed(Duration.zero);

void main() {
  setUpAll(() {
    registerFallbackValue(CancelToken());
    registerFallbackValue(account);
  });
  late Repo repo;
  late Completer<AccountLoginResult> network;
  setUp(() {
    repo = Repo();
    network = Completer<AccountLoginResult>();
    when(() => repo.loginWithAccount(
            username: any(named: 'username'),
            password: any(named: 'password'),
            checkEx: any(named: 'checkEx'),
            cancelToken: any(named: 'cancelToken')))
        .thenAnswer((_) => network.future);
    when(() => repo.logout()).thenAnswer((_) async {});
    when(() => repo.saveAccountLogin(any(),
        isCurrent: any(named: 'isCurrent'),
        onCommitted: any(named: 'onCommitted'))).thenAnswer((call) async {
      if ((call.namedArguments[#isCurrent] as bool Function())()) {
        (call.namedArguments[#onCommitted] as void Function())();
      }
    });
  });
  test('success commits verified account and EX notice, never logs password',
      () async {
    final bloc = AuthBloc(repo)..add(event);
    await drain();
    network.complete(account);
    await drain();
    expect(bloc.state.status, AuthStatus.authenticated);
    expect(bloc.state.exUnavailable, isTrue);
    expect(bloc.state.profile.memberId, '123');
    expect(event.toString(), isNot(contains('secret')));
    await bloc.close();
  });
  for (final logout in [false, true]) {
    test(
        'late network result cannot commit after ${logout ? "logout" : "cancel"}',
        () async {
      final bloc = AuthBloc(repo)..add(event);
      await drain();
      if (logout) {
        bloc.add(LogoutRequested());
      } else {
        bloc.cancelAccountLogin();
      }
      await drain();
      network.complete(account);
      await drain();
      expect(bloc.state.status, AuthStatus.unauthenticated);
      verifyNever(() => repo.saveAccountLogin(any(),
          isCurrent: any(named: 'isCurrent'),
          onCommitted: any(named: 'onCommitted')));
      await bloc.close();
    });
  }
  test('leaving screen before the queued event runs prevents network work',
      () async {
    final token = CancelToken();
    final bloc = AuthBloc(repo)
      ..add(LoginWithAccount(
          username: 'test',
          password: 'secret',
          sessionGeneration: 0,
          cancelToken: token));
    token.cancel();
    await drain();
    verifyNever(() => repo.loginWithAccount(
        username: any(named: 'username'),
        password: any(named: 'password'),
        checkEx: any(named: 'checkEx'),
        cancelToken: any(named: 'cancelToken')));
    await bloc.close();
  });
  test('duplicate account or background WebView cannot overtake login',
      () async {
    final bloc = AuthBloc(repo)
      ..add(event)
      ..add(event)
      ..add(const LoginFromWebView(
          {'ipb_member_id': 'old', 'ipb_pass_hash': 'old'}));
    await drain();
    verify(() => repo.loginWithAccount(
        username: any(named: 'username'),
        password: any(named: 'password'),
        checkEx: any(named: 'checkEx'),
        cancelToken: any(named: 'cancelToken'))).called(1);
    network.complete(account);
    await drain();
    expect(bloc.state.profile.memberId, '123');
    await bloc.close();
  });
  test('cancellation while persistence waits makes commit guard false',
      () async {
    final saving = Completer<void>();
    bool Function()? guard;
    when(() => repo.saveAccountLogin(any(),
        isCurrent: any(named: 'isCurrent'),
        onCommitted: any(named: 'onCommitted'))).thenAnswer((call) async {
      guard = call.namedArguments[#isCurrent] as bool Function();
      await saving.future;
      expect(guard!(), isFalse);
    });
    final bloc = AuthBloc(repo)..add(event);
    network.complete(account);
    await drain();
    expect(guard!(), isTrue);
    bloc.cancelAccountLogin();
    saving.complete();
    await drain();
    expect(bloc.state.status, AuthStatus.unauthenticated);
    await bloc.close();
  });
  for (final reason in AccountLoginFailure.values) {
    test('$reason remains a typed, recoverable error', () async {
      final bloc = AuthBloc(repo)..add(event);
      await drain();
      network.completeError(AccountLoginException(reason));
      await drain();
      expect(bloc.state.accountFailure, reason);
      expect(bloc.state.status, AuthStatus.error);
      await bloc.close();
    });
  }
}
