import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/parser/dawn_parser.dart';
import '../../models/daily_check_in.dart';
import '../../repositories/daily_check_in_repository.dart';

class _RequestScope {
  final int generation;
  final String day;
  _RequestScope(this.generation, this.day);
}

class DailyCheckInCubit extends Cubit<DailyCheckInState> {
  final DailyCheckInRepository repository;
  final DateTime Function() now;
  bool _foreground = false;
  bool _firstFrame = false;
  int _generation = 0;
  Timer? _timer;
  CancelToken? _request;
  Future<void>? _writes;
  final Map<String, DailyCheckInRecord> _records = {};

  DailyCheckInCubit(this.repository, {DateTime Function()? clock})
      : now = clock ?? DateTime.now,
        super(DailyCheckInState(
            enabled: repository.enabled,
            record: DailyCheckInRecord(
                day: checkInDay((clock ?? DateTime.now)()))));

  void firstFrameReady() {
    _firstFrame = true;
    _tick();
  }

  void setForeground(bool value) {
    _foreground = value;
    _timer?.cancel();
    if (value) _tick();
  }

  void setAccount(String? memberId, {bool renewSession = false}) {
    if (isClosed || (state.memberId == memberId && !renewSession)) return;
    _invalidate();
    final day = checkInDay(now());
    final cached = _records[memberId];
    emit(DailyCheckInState(
        enabled: state.enabled,
        memberId: memberId,
        record: memberId == null
            ? DailyCheckInRecord(day: day)
            : cached?.day == day
                ? cached!
                : repository.read(memberId, day)));
    _tick();
  }

  void _invalidate() {
    if (_request != null && state.status == CheckInStatus.running) {
      final r = state.record;
      _publish(DailyCheckInRecord(
          day: r.day,
          status: CheckInStatus.unconfirmed,
          automaticAttempts: r.automaticAttempts,
          lastAttempt: r.lastAttempt,
          nextAttempt: r.nextAttempt));
    }
    _generation++;
    _timer?.cancel();
    _request?.cancel('Session changed');
    _request = null;
  }

  Future<void> setEnabled(bool value) async {
    try {
      await repository.setEnabled(value);
      if (isClosed) return;
      if (!value) _invalidate();
      final r = state.record;
      emit(DailyCheckInState(
          enabled: value,
          memberId: state.memberId,
          record: r.status == CheckInStatus.running
              ? DailyCheckInRecord(
                  day: r.day,
                  status: CheckInStatus.unconfirmed,
                  automaticAttempts: r.automaticAttempts,
                  lastAttempt: r.lastAttempt,
                  nextAttempt: r.nextAttempt)
              : r));
      _tick();
    } catch (_) {
      _storageError();
    }
  }

  void _storageError() {
    if (!isClosed) {
      emit(DailyCheckInState(
          enabled: state.enabled,
          memberId: state.memberId,
          record: state.record,
          storageFailed: true));
    }
  }

  void _publish(DailyCheckInRecord record) {
    if (isClosed || state.memberId == null) return;
    final id = state.memberId!;
    final generation = _generation;
    _records[id] = record;
    emit(DailyCheckInState(
        enabled: state.enabled, memberId: id, record: record));
    _writes = (_writes ?? Future<void>.value())
        .then((_) => repository.save(id, record))
        .catchError((Object _) {
      if (!isClosed && generation == _generation) _storageError();
    });
  }

  void _refreshDay() {
    if (state.record.day == checkInDay(now())) return;
    final id = state.memberId;
    _invalidate();
    emit(DailyCheckInState(
        enabled: state.enabled,
        memberId: id,
        record: DailyCheckInRecord(day: checkInDay(now()))));
  }

  void _tick() {
    if (isClosed) return;
    _refreshDay();
    if (!_foreground || !_firstFrame || state.memberId == null) return;
    unawaited(check());
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (isClosed || !_foreground || !_firstFrame || state.memberId == null) {
      return;
    }
    final time = now().toUtc();
    var due = DateTime.utc(time.year, time.month, time.day + 1);
    final retry = state.record.nextAttempt;
    if (state.enabled &&
        state.status != CheckInStatus.confirmed &&
        state.record.automaticAttempts < 3 &&
        retry != null &&
        retry.isAfter(time) &&
        retry.isBefore(due)) {
      due = retry;
    }
    _timer = Timer(due.difference(time), _tick);
  }

  bool get canCheckManually {
    final last = state.record.lastAttempt;
    return state.memberId != null &&
        _request == null &&
        state.status != CheckInStatus.confirmed &&
        (last == null || now().difference(last) >= const Duration(seconds: 30));
  }

  Future<void> check({bool manual = false}) async {
    if (isClosed) return;
    _refreshDay();
    if (!_firstFrame ||
        !_foreground ||
        state.memberId == null ||
        _request != null ||
        state.status == CheckInStatus.confirmed) return;
    final old = state.record;
    if (manual) {
      if (!canCheckManually) return;
    } else if (!state.enabled ||
        old.automaticAttempts >= 3 ||
        (old.nextAttempt != null && now().isBefore(old.nextAttempt!))) {
      return;
    }
    final generation = _generation;
    final day = old.day;
    final token = CancelToken();
    _request = token;
    final attempts = old.automaticAttempts + (manual ? 0 : 1);
    final started = now().toUtc();
    final next = started.add(Duration(minutes: attempts <= 1 ? 5 : 30));
    _publish(DailyCheckInRecord(
        day: day,
        status: CheckInStatus.running,
        automaticAttempts: attempts,
        lastAttempt: started,
        nextAttempt: next));
    try {
      final result = await repository.check(token);
      if (!_valid(generation, day) || state.status == CheckInStatus.confirmed) {
        return;
      }
      if (result.confirmed) {
        _confirmed(result.rewards);
      } else {
        _publish(DailyCheckInRecord(
            day: day,
            status: CheckInStatus.unconfirmed,
            automaticAttempts: attempts,
            lastAttempt: started,
            nextAttempt: next));
      }
    } catch (_) {
      if (_valid(generation, day) && state.status != CheckInStatus.confirmed) {
        _publish(DailyCheckInRecord(
            day: day,
            status: CheckInStatus.failed,
            automaticAttempts: attempts,
            lastAttempt: started,
            nextAttempt: next));
      }
    } finally {
      if (identical(_request, token)) _request = null;
      if (!isClosed && generation == _generation) {
        _refreshDay();
        _schedule();
        if (day != state.record.day) _tick();
      }
    }
  }

  bool _valid(int generation, String day) =>
      !isClosed &&
      _generation == generation &&
      state.memberId != null &&
      checkInDay(now()) == day;

  Object? captureResponseScope() => state.memberId == null
      ? null
      : _RequestScope(_generation, checkInDay(now()));
  void observeResponse(Uri uri, String source, Object? scope) {
    if (scope is! _RequestScope ||
        !_valid(scope.generation, scope.day) ||
        state.status == CheckInStatus.confirmed ||
        uri.scheme != 'https' ||
        !{'e-hentai.org', 'exhentai.org'}.contains(uri.host) ||
        !(uri.path == '/news.php' ||
            RegExp(r'^/g/\d+/[a-f0-9]+/$').hasMatch(uri.path))) return;
    if (!source.contains('eventpane')) return;
    try {
      final result = DawnParser.parse(source);
      if (result.confirmed) _confirmed(result.rewards);
    } catch (_) {/* Unrelated pages and verification errors aren't success. */}
  }

  void _confirmed(String rewards) {
    final old = state.record;
    _publish(DailyCheckInRecord(
        day: checkInDay(now()),
        status: CheckInStatus.confirmed,
        automaticAttempts: old.automaticAttempts,
        lastAttempt: old.lastAttempt,
        rewards: rewards));
    _schedule();
  }

  Future<void> markNotified(String memberId, String day) async {
    if (state.memberId != memberId ||
        state.record.day != day ||
        !state.needsDialog) return;
    final r = state.record;
    _publish(DailyCheckInRecord(
        day: r.day,
        status: r.status,
        automaticAttempts: r.automaticAttempts,
        lastAttempt: r.lastAttempt,
        rewards: r.rewards,
        notified: true));
    await _writes;
  }

  @override
  Future<void> close() async {
    if (isClosed) return;
    _invalidate();
    await _writes;
    return super.close();
  }
}
