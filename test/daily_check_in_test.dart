import 'package:flutter/foundation.dart';
import 'core/network/comment_redirect_test.dart'
    show client, RedirectAdapter, FakeDio;
import 'package:oviewer/core/network/network_proxy_io.dart';
import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:mocktail/mocktail.dart';
import 'package:oviewer/blocs/auth/auth_bloc.dart';
import 'package:oviewer/blocs/auth/auth_state.dart';
import 'package:oviewer/blocs/settings/settings_bloc.dart';
import 'package:oviewer/blocs/settings/settings_state.dart';
import 'package:oviewer/blocs/daily_check_in/daily_check_in_cubit.dart';
import 'package:oviewer/core/network/dio_client.dart';
import 'package:oviewer/core/parser/dawn_parser.dart';
import 'package:oviewer/core/storage/local_storage.dart';
import 'package:oviewer/models/daily_check_in.dart';
import 'package:oviewer/models/user_profile.dart';
import 'package:oviewer/repositories/daily_check_in_repository.dart';
import 'package:oviewer/widgets/daily_check_in_host.dart';
import 'package:oviewer/widgets/daily_check_in_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockDio extends Mock implements DioClient {}

class MockAuthBloc extends Mock implements AuthBloc {}

class MockSettingsBloc extends Mock implements SettingsBloc {}

// Deliberately synthetic fixtures; real-site acceptance is documented separately.
const dawn = '<div id="eventpane"><p>It is the dawn of a new day!</p>'
    '<p>You gain 12,345 EXP, 500 Credits and 1 Hath.</p></div>';
const news =
    '<div id="newsinner"><div id="nb"><a href="https://e-hentai.org/">Front Page</a></div><table id="nt"><tr><td>News</td></tr></table></div>';

class FakeRepository extends DailyCheckInRepository {
  final List<CancelToken> tokens = [];
  final List<Completer<DawnResult>> replies = [];
  FakeRepository(super.dio, super.storage);
  @override
  Future<DawnResult> check(CancelToken token) {
    tokens.add(token);
    final reply = Completer<DawnResult>();
    replies.add(reply);
    return reply.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => registerFallbackValue(FakeDio()));
  tearDown(() => NetworkProxy.beforeRequest = null);
  late LocalStorage storage;
  late FakeRepository repository;
  late DateTime time;
  late DailyCheckInCubit cubit;
  DailyCheckInCubit? activeCubit;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = LocalStorage();
    await storage.init();
    repository = FakeRepository(MockDio(), storage);
    time = DateTime.utc(2026, 10, 3, 12);
    activeCubit = null;
  });
  tearDown(() async {
    if (activeCubit != null && !activeCubit!.isClosed)
      await activeCubit!.close();
    await GetIt.I.reset();
  });
  void checkWidgets(
      String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      cubit = DailyCheckInCubit(repository, clock: () => time);
      activeCubit = cubit;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        await tester.pumpWidget(const SizedBox.shrink());
        final closing = cubit.close();
        await tester.pump();
        await closing;
      }
    });
  }

  void ready() {
    cubit.setAccount('1');
    cubit.setForeground(true);
    cubit.firstFrameReady();
  }

  test('only the event pane confirms Dawn, not news, scripts or comments', () {
    final result = DawnParser.parse(dawn);
    expect(result.confirmed, isTrue);
    expect(result.rewards, contains('12,345 EXP'));
    expect(
        DawnParser.parse(
                news.replaceFirst('News', 'It is the dawn of a new day!'))
            .confirmed,
        isFalse);
    expect(DawnParser.parse('$news<script>$dawn</script>').confirmed, isFalse);
    expect(
        DawnParser.parse(news.replaceFirst('News', dawn)).confirmed, isFalse);
    expect(
        DawnParser.parse('$news<div id="cdiv">$dawn</div>').confirmed, isFalse);
    expect(
        DawnParser.parse(
                '$news<div id="eventpane">A monster has appeared!</div>')
            .confirmed,
        isFalse);
    expect(
        DawnParser.parse(
                '$news<div id="eventpane"><script>It is the dawn of a new day!</script></div>')
            .confirmed,
        isFalse);
  });
  test('login, challenge, banned and malformed pages never confirm', () {
    for (final page in [
      '<title>E-Hentai.org Login</title>$dawn',
      '<title>Just a moment...</title>$dawn',
      '<form id="challenge-form"></form>$dawn',
      'Your IP has been temporarily banned',
      '',
      '<html>unrecognized</html>'
    ]) {
      expect(() => DawnParser.parse(page), throwsFormatException);
    }
  });
  test('reward paragraphs preserve the actual observed message and amounts',
      () {
    // Reward text observed on the Android device on 2026-10-03; wrapper is synthetic.
    const message = '<div id="eventpane"><p>It is the dawn of a new day!</p>'
        '<p>Reflecting on your journey so far, you find that you are a little wiser.</p>'
        '<p>You gain 30 EXP, 2,209 Credits and 2,000 GP!</p></div>';
    final result = DawnParser.parse(message);
    expect(result.confirmed, isTrue);
    expect(result.rewards,
        contains('wiser.\nYou gain 30 EXP, 2,209 Credits and 2,000 GP!'));
  });
  test('date uses UTC, not local midnight', () {
    expect(
        checkInDay(DateTime.parse('2026-10-03T07:59:59+08:00')), '2026-10-02');
    expect(
        checkInDay(DateTime.parse('2026-10-03T08:00:00+08:00')), '2026-10-03');
  });
  checkWidgets(
      'first frame and foreground gate; concurrent triggers share one request',
      (tester) async {
    cubit.setAccount('1');
    cubit.setForeground(true);
    expect(repository.replies, isEmpty);
    cubit.firstFrameReady();
    cubit.setForeground(true);
    await cubit.check(manual: true);
    expect(repository.replies, hasLength(1));
    repository.replies.single
        .complete(const DawnResult(confirmed: true, rewards: '500 Credits'));
    await tester.pump();
    expect(cubit.state.needsDialog, isTrue);
    cubit.setForeground(false);
    cubit.setForeground(true);
    await cubit.check(manual: true);
    expect(repository.replies, hasLength(1));
    final notified = cubit.markNotified('1', '2026-10-03');
    await tester.pump();
    await notified;
    expect(cubit.state.needsDialog, isFalse);
    expect(repository.read('1', '2026-10-03').notified, isTrue);
  });
  checkWidgets(
      'failure and unconfirmed retry after 5 and 30 minutes, three automatic attempts max',
      (tester) async {
    ready();
    repository.replies[0].completeError(StateError('offline'));
    await tester.pump();
    expect(cubit.state.status, CheckInStatus.failed);
    time = time.add(const Duration(minutes: 5));
    await tester.pump(const Duration(minutes: 5));
    expect(repository.replies, hasLength(2));
    repository.replies[1].complete(const DawnResult());
    await tester.pump();
    expect(cubit.state.status, CheckInStatus.unconfirmed);
    time = time.add(const Duration(minutes: 30));
    await tester.pump(const Duration(minutes: 30));
    expect(repository.replies, hasLength(3));
    repository.replies[2].complete(const DawnResult());
    await tester.pump();
    time = time.add(const Duration(hours: 2));
    await tester.pump(const Duration(hours: 2));
    cubit.setForeground(true);
    expect(repository.replies, hasLength(3));
    final manual = cubit.check(manual: true);
    expect(repository.replies, hasLength(4));
    repository.replies[3].complete(const DawnResult());
    await manual;
    expect(cubit.canCheckManually, isFalse);
  });
  checkWidgets('no background attempts; reopening resumes an overdue retry',
      (tester) async {
    ready();
    repository.replies[0].complete(const DawnResult());
    await tester.pump();
    cubit.setForeground(false);
    time = time.add(const Duration(minutes: 10));
    await tester.pump(const Duration(minutes: 10));
    expect(repository.replies, hasLength(1));
    cubit.setForeground(true);
    expect(repository.replies, hasLength(2));
  });
  checkWidgets('off disables automatic work but allows manual check-in',
      (tester) async {
    await cubit.setEnabled(false);
    ready();
    expect(repository.replies, isEmpty);
    final pending = cubit.check(manual: true);
    repository.replies.single.complete(const DawnResult(confirmed: true));
    await pending;
    expect(cubit.state.needsDialog, isTrue);
    expect(storage.prefs.getBool('auto_check_in'), isFalse);
  });
  checkWidgets(
      'logout cancels and discards old results; accounts remain isolated',
      (tester) async {
    ready();
    final oldScope = cubit.captureResponseScope();
    cubit.setAccount(null);
    expect(repository.tokens[0].isCancelled, isTrue);
    cubit.setAccount('2');
    repository.replies[0].complete(const DawnResult(confirmed: true));
    cubit.observeResponse(
        Uri.parse(DailyCheckInRepository.newsUrl), dawn, oldScope);
    await tester.pump();
    expect(cubit.state.status, CheckInStatus.running);
    repository.replies[1].complete(const DawnResult());
    await tester.pump();
    expect(
        repository.read('2', '2026-10-03').status, CheckInStatus.unconfirmed);
    expect(repository.read('1', '2026-10-03').status,
        isNot(CheckInStatus.confirmed));
  });
  checkWidgets('gallery Dawn beats an overlapping unconfirmed news request',
      (tester) async {
    ready();
    final scope = cubit.captureResponseScope();
    cubit.observeResponse(
        Uri.parse('https://e-hentai.org/g/123/abcdef/'), dawn, scope);
    repository.replies.single.complete(const DawnResult());
    await tester.pump();
    expect(cubit.state.status, CheckInStatus.confirmed);
    expect(cubit.state.record.rewards, contains('500 Credits'));
    final notified = cubit.markNotified('1', '2026-10-03');
    await tester.pump();
    await notified;
    cubit.observeResponse(
        Uri.parse('https://exhentai.org/g/123/abcdef/'), dawn, scope);
    expect(cubit.state.needsDialog, isFalse);
  });
  checkWidgets('foreign hosts and list pages cannot publish a Dawn event',
      (tester) async {
    ready();
    final scope = cubit.captureResponseScope();
    for (final url in [
      'https://e-hentai.org.example/news.php',
      'http://e-hentai.org/news.php',
      'https://e-hentai.org/'
    ]) {
      cubit.observeResponse(Uri.parse(url), dawn, scope);
      expect(cubit.state.status, CheckInStatus.running);
    }
  });
  checkWidgets(
      'midnight resets and a late previous-day response cannot claim the new day',
      (tester) async {
    time = DateTime.utc(2026, 10, 3, 23, 59, 59);
    ready();
    time = time.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(repository.tokens[0].isCancelled, isTrue);
    expect(repository.replies, hasLength(2));
    repository.replies[0].complete(const DawnResult(confirmed: true));
    await tester.pump();
    expect(cubit.state.record.day, '2026-10-04');
    expect(cubit.state.status, CheckInStatus.running);
  });
  checkWidgets('saved result survives restart and resets next UTC day',
      (tester) async {
    ready();
    repository.replies[0].complete(const DawnResult(confirmed: true));
    await tester.pump();
    final notified = cubit.markNotified('1', '2026-10-03');
    await tester.pump();
    await notified;
    await cubit.close();
    cubit = DailyCheckInCubit(repository, clock: () => time);
    ready();
    expect(cubit.state.status, CheckInStatus.confirmed);
    expect(repository.replies, hasLength(1));
    time = time.add(const Duration(days: 1));
    cubit.setForeground(true);
    expect(repository.replies, hasLength(2));
  });
  checkWidgets('repository timeout includes a stalled request and cancels it',
      (tester) async {
    final dio = MockDio();
    final token = CancelToken();
    when(() => dio.get(DailyCheckInRepository.newsUrl,
        cancelToken: token, followRedirects: false)).thenAnswer((_) async {
      throw await token.whenCancel;
    });
    final repo = DailyCheckInRepository(dio, storage,
        timeout: const Duration(seconds: 1));
    final future = expectLater(repo.check(token), throwsA(isA<DioException>()));
    await tester.pump(const Duration(seconds: 1));
    await future;
    expect(token.isCancelled, isTrue);
  });

  test(
      'Dio response observation captures scope and cannot break normal requests',
      () async {
    final adapter =
        RedirectAdapter((_, __) => ResponseBody.fromString(dawn, 200));
    final dio = client(adapter);
    final scope = Object();
    Object? observed;
    dio.captureResponseScope = () => scope;
    dio.onHtmlResponse = (uri, source, captured) {
      observed = captured;
      expect(uri.toString(), DailyCheckInRepository.newsUrl);
      expect(source, dawn);
      throw StateError('optional observer failure');
    };
    expect(await dio.get(DailyCheckInRepository.newsUrl), dawn);
    expect(observed, same(scope));
    dio.captureResponseScope = () => throw StateError('capture failed');
    expect(await dio.get(DailyCheckInRepository.newsUrl), dawn);
  });
  test('news request never follows a redirect to an unrelated endpoint',
      () async {
    final adapter =
        RedirectAdapter((_, __) => ResponseBody.fromString('', 302, headers: {
              'location': ['https://example.test/']
            }));
    final repo = DailyCheckInRepository(client(adapter), storage);
    await expectLater(repo.check(CancelToken()), throwsA(anything));
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.followRedirects, isFalse);
  });
  test('real Dio timeout cancels while waiting for network preparation',
      () async {
    final ready = Completer<void>();
    NetworkProxy.beforeRequest = () => ready.future;
    final adapter =
        RedirectAdapter((_, __) => ResponseBody.fromString(dawn, 200));
    final repo = DailyCheckInRepository(client(adapter), storage,
        timeout: const Duration(milliseconds: 30));
    final token = CancelToken();
    await expectLater(repo.check(token), throwsA(isA<DioException>()));
    expect(token.isCancelled, isTrue);
    ready.complete();
    await Future<void>.delayed(Duration.zero);
    expect(adapter.requests, isEmpty);
  });
  checkWidgets(
      'turning automatic off cancels pending result and manual retry remains possible',
      (tester) async {
    ready();
    await cubit.setEnabled(false);
    expect(repository.tokens.single.isCancelled, isTrue);
    repository.replies.single.complete(const DawnResult(confirmed: true));
    await tester.pump();
    expect(cubit.state.needsDialog, isFalse);
    expect(cubit.state.status, CheckInStatus.unconfirmed);
    time = time.add(const Duration(seconds: 30));
    final retry = cubit.check(manual: true);
    repository.replies.last.complete(const DawnResult(confirmed: true));
    await retry;
    expect(cubit.state.needsDialog, isTrue);
  });
  checkWidgets(
      'returning to an account before writes finish still deduplicates',
      (tester) async {
    ready();
    cubit.observeResponse(Uri.parse(DailyCheckInRepository.newsUrl), dawn,
        cubit.captureResponseScope());
    cubit.setAccount(null);
    cubit.setAccount('1');
    expect(cubit.state.status, CheckInStatus.confirmed);
    expect(repository.replies, hasLength(1));
  });

  checkWidgets(
      'disabled automatic requests still observe explicit gallery rewards',
      (tester) async {
    await cubit.setEnabled(false);
    ready();
    expect(repository.replies, isEmpty);
    cubit.observeResponse(Uri.parse('https://exhentai.org/g/123/abcdef/'), dawn,
        cubit.captureResponseScope());
    await tester.pump();
    expect(cubit.state.status, CheckInStatus.confirmed);
    expect(cubit.state.needsDialog, isTrue);
    expect(repository.read('1', '2026-10-03').status, CheckInStatus.confirmed);
    expect(repository.replies, isEmpty);
  });

  for (final locale in ['zh', 'en']) {
    checkWidgets(
        '$locale signed-out settings are disabled and react to login/logout',
        (tester) async {
      final settings = MockSettingsBloc();
      when(() => settings.stream)
          .thenAnswer((_) => const Stream<SettingsState>.empty());
      when(() => settings.state).thenReturn(SettingsState(locale: locale));
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settings,
          child: MaterialApp(
              home: Scaffold(body: DailyCheckInTile(cubit: cubit)))));
      final daily = find.widgetWithText(
          ListTile, locale == 'zh' ? '今日签到' : 'Daily check-in');
      expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
          isNull);
      expect(tester.widget<ListTile>(daily).enabled, isFalse);
      expect(
          tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
      await tester
          .tap(find.text(locale == 'zh' ? '自动签到' : 'Automatic check-in'));
      expect(cubit.state.enabled, isTrue);
      expect(repository.replies, isEmpty);
      cubit.setAccount('1');
      await tester.pump();
      expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
          isNotNull);
      expect(tester.widget<ListTile>(daily).enabled, isTrue);
      cubit.setAccount(null);
      await tester.pump();
      expect(
          tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
          isNull);
      expect(tester.widget<ListTile>(daily).enabled, isFalse);
    });
    checkWidgets(
        '$locale settings preserve manual check-in when automatic is off',
        (tester) async {
      final settings = MockSettingsBloc();
      when(() => settings.stream)
          .thenAnswer((_) => const Stream<SettingsState>.empty());
      when(() => settings.state).thenReturn(SettingsState(locale: locale));
      await cubit.setEnabled(false);
      cubit.setAccount('1');
      cubit.setForeground(true);
      cubit.firstFrameReady();
      await tester.pumpWidget(BlocProvider<SettingsBloc>.value(
          value: settings,
          child: MaterialApp(
              home: Scaffold(body: DailyCheckInTile(cubit: cubit)))));
      expect(find.text(locale == 'zh' ? '自动签到' : 'Automatic check-in'),
          findsOneWidget);
      await tester.tap(find.text(locale == 'zh' ? '手动签到' : 'Check in'));
      await tester.pump();
      expect(repository.replies, hasLength(1));
      repository.replies.single.complete(const DawnResult());
      await tester.pump();
      expect(find.text(locale == 'zh' ? '重试' : 'Retry'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    checkWidgets(
        '$platform success popup waits for another modal and is shown only once',
        (tester) async {
      time = DateTime.now().toUtc();
      debugDefaultTargetPlatformOverride = platform;

      final auth = MockAuthBloc();
      when(() => auth.state).thenReturn(const AuthState(
          status: AuthStatus.authenticated,
          profile: UserProfile(memberId: '1', isLoggedIn: true)));
      when(() => auth.stream)
          .thenAnswer((_) => const Stream<AuthState>.empty());
      final settings = MockSettingsBloc();
      when(() => settings.stream)
          .thenAnswer((_) => const Stream<SettingsState>.empty());
      when(() => settings.state).thenReturn(const SettingsState(locale: 'en'));
      GetIt.I.registerSingleton<DailyCheckInCubit>(cubit);
      late BuildContext page;
      await tester.pumpWidget(MultiBlocProvider(
          providers: [
            BlocProvider<AuthBloc>.value(value: auth),
            BlocProvider<SettingsBloc>.value(value: settings)
          ],
          child: DailyCheckInHost(
              builder: (key, observer) => MaterialApp(
                  navigatorKey: key,
                  navigatorObservers: [observer],
                  home: Builder(builder: (context) {
                    page = context;
                    return const Scaffold(body: Text('Home'));
                  })))));
      await tester.pump();
      cubit.firstFrameReady();
      unawaited(showDialog<void>(
          context: page,
          builder: (context) => AlertDialog(
                  title: const Text('Existing modal'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'))
                  ])));
      await tester.pumpAndSettle();
      repository.replies.single
          .complete(const DawnResult(confirmed: true, rewards: '500 Credits'));
      await tester.pumpAndSettle();
      expect(find.text('Check-in successful'), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Check-in successful'), findsOneWidget);
      expect(find.text('500 Credits'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      cubit.setForeground(true);
      await tester.pumpAndSettle();
      expect(find.text('Check-in successful'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
