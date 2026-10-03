import 'dart:async';
import 'package:oviewer/core/network/native_auth_cookies.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_event.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/repositories/auth_repository.dart';
import 'package:oviewer/models/user_profile.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

void main() {
  late MockAuthRepository mockRepo;

  setUp(() {
    mockRepo = MockAuthRepository();
  });

  group('AuthBloc', () {
    blocTest<AuthBloc, AuthState>(
      'CheckLoginStatus emits authenticated when logged in',
      setUp: () {
        when(() => mockRepo.isLoggedIn()).thenAnswer((_) async => true);
        when(() => mockRepo.getUserProfile()).thenAnswer(
          (_) async => const UserProfile(
            memberId: '12345',
            isLoggedIn: true,
          ),
        );
      },
      build: () => AuthBloc(mockRepo),
      act: (bloc) => bloc.add(CheckLoginStatus()),
      expect: () => [
        isA<AuthState>()
            .having((s) => s.status, 'status', AuthStatus.authenticated)
            .having((s) => s.profile.memberId, 'memberId', '12345'),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'CheckLoginStatus emits unauthenticated when not logged in',
      setUp: () {
        when(() => mockRepo.isLoggedIn()).thenAnswer((_) async => false);
      },
      build: () => AuthBloc(mockRepo),
      act: (bloc) => bloc.add(CheckLoginStatus()),
      expect: () => [
        isA<AuthState>()
            .having((s) => s.status, 'status', AuthStatus.unauthenticated),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'LogoutRequested clears session',
      setUp: () {
        when(() => mockRepo.logout()).thenAnswer((_) async {});
      },
      build: () => AuthBloc(mockRepo),
      seed: () => const AuthState(
        status: AuthStatus.authenticated,
        profile: UserProfile(memberId: '123', isLoggedIn: true),
      ),
      act: (bloc) => bloc.add(LogoutRequested()),
      expect: () => [
        isA<AuthState>()
            .having((s) => s.status, 'status', AuthStatus.loggingOut),
        isA<AuthState>()
            .having((s) => s.status, 'status', AuthStatus.unauthenticated),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'LoginWithCookies validates and emits authenticated',
      setUp: () {
        when(() => mockRepo.saveLoginCookies(
              memberId: any(named: 'memberId'),
              passHash: any(named: 'passHash'),
              igneous: any(named: 'igneous'),
            )).thenAnswer((_) async {});
        when(() => mockRepo.validateLogin()).thenAnswer((_) async => true);
        when(() => mockRepo.getUserProfile()).thenAnswer(
          (_) async => const UserProfile(memberId: '99', isLoggedIn: true),
        );
      },
      build: () => AuthBloc(mockRepo),
      act: (bloc) => bloc.add(const LoginWithCookies(
        memberId: '99',
        passHash: 'hash123',
      )),
      expect: () => [
        isA<AuthState>().having((s) => s.status, 'status', AuthStatus.loading),
        isA<AuthState>()
            .having((s) => s.status, 'status', AuthStatus.authenticated),
      ],
    );
  });

  Future<void> drain() => Future<void>.delayed(Duration.zero);
  void stubLogin() {
    when(() => mockRepo.saveLoginCookies(
        memberId: any(named: 'memberId'),
        passHash: any(named: 'passHash'),
        igneous: any(named: 'igneous'))).thenAnswer((_) async {});
    when(() => mockRepo.logout()).thenAnswer((_) async {});
  }

  test('a delayed initial profile cannot restore the account after logout',
      () async {
    final profile = Completer<UserProfile>();
    when(() => mockRepo.isLoggedIn()).thenAnswer((_) async => true);
    when(() => mockRepo.getUserProfile()).thenAnswer((_) => profile.future);
    when(() => mockRepo.logout()).thenAnswer((_) async {});
    final bloc = AuthBloc(mockRepo)..add(CheckLoginStatus());
    await drain();
    bloc.add(LogoutRequested());
    await drain();
    expect(bloc.state.status, AuthStatus.unauthenticated);
    profile.complete(const UserProfile(memberId: 'old', isLoggedIn: true));
    await drain();
    expect(bloc.state.status, AuthStatus.unauthenticated);
    expect(bloc.state.profile.memberId, isNull);
    await bloc.close();
  });

  for (final valid in [true, false]) {
    test(
        'late manual login validation ($valid) cannot undo logout or clear a newer login',
        () async {
      stubLogin();
      final validation = Completer<bool>();
      when(() => mockRepo.validateLogin()).thenAnswer((_) => validation.future);
      when(() => mockRepo.getUserProfile()).thenAnswer(
          (_) async => const UserProfile(memberId: 'new', isLoggedIn: true));
      final bloc = AuthBloc(mockRepo)
        ..add(const LoginWithCookies(memberId: 'old', passHash: 'test'));
      await drain();
      bloc.add(LogoutRequested());
      await drain();
      final generation = bloc.state.sessionGeneration;
      bloc.add(LoginFromWebView(
          const {'ipb_member_id': 'new', 'ipb_pass_hash': 'test'},
          sessionGeneration: generation));
      await drain();
      expect(bloc.state.profile.memberId, 'new');
      validation.complete(valid);
      await drain();
      expect(bloc.state.profile.memberId, 'new');
      expect(bloc.state.status, AuthStatus.authenticated);
      verify(() => mockRepo.logout()).called(1);
      await bloc.close();
    });
  }

  test(
      'logout blocks old WebView callbacks and coalesces repeated exit requests',
      () async {
    stubLogin();
    final clearing = Completer<void>();
    when(() => mockRepo.logout()).thenAnswer((_) => clearing.future);
    final bloc = AuthBloc(mockRepo)..add(LogoutRequested());
    await drain();
    expect(bloc.state.status, AuthStatus.loggingOut);
    expect(bloc.state.isLoggedIn, isFalse);
    bloc.add(LogoutRequested());
    bloc.add(const LoginFromWebView(
        {'ipb_member_id': 'old', 'ipb_pass_hash': 'test'},
        sessionGeneration: 0));
    await drain();
    clearing.complete();
    await drain();
    bloc.add(const LoginFromWebView(
        {'ipb_member_id': 'old', 'ipb_pass_hash': 'test'},
        sessionGeneration: 0));
    await drain();
    expect(bloc.state.status, AuthStatus.unauthenticated);
    verifyNever(() => mockRepo.saveLoginCookies(
        memberId: any(named: 'memberId'),
        passHash: any(named: 'passHash'),
        igneous: any(named: 'igneous')));
    verify(() => mockRepo.logout()).called(1);
    await bloc.close();
  });

  test(
      'pending cleanup failure keeps login blocked until explicit retry succeeds',
      () async {
    when(() => mockRepo.isLoggedIn()).thenThrow(const LogoutCleanupException());
    when(() => mockRepo.logout()).thenAnswer((_) async {});
    final bloc = AuthBloc(mockRepo)..add(CheckLoginStatus());
    await drain();
    expect(bloc.state.status, AuthStatus.logoutFailed);
    bloc.add(const LoginWithCookies(memberId: 'old', passHash: 'test'));
    await drain();
    verifyNever(() => mockRepo.saveLoginCookies(
        memberId: any(named: 'memberId'),
        passHash: any(named: 'passHash'),
        igneous: any(named: 'igneous')));
    bloc.add(LogoutRequested());
    await drain();
    expect(bloc.state.status, AuthStatus.unauthenticated);
    await bloc.close();
  });
}
