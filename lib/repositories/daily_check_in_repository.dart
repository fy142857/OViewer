import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../core/network/dio_client.dart';
import '../core/parser/dawn_parser.dart';
import '../core/storage/local_storage.dart';
import '../models/daily_check_in.dart';

class DailyCheckInRepository {
  static const newsUrl = 'https://e-hentai.org/news.php';
  final DioClient dio;
  final LocalStorage storage;
  final Duration timeout;
  DailyCheckInRepository(this.dio, this.storage,
      {this.timeout = const Duration(seconds: 20)});

  bool get enabled => storage.prefs.getBool('auto_check_in') ?? true;
  Future<void> setEnabled(bool value) async {
    if (!await storage.prefs.setBool('auto_check_in', value)) {
      throw StateError('Could not save automatic check-in preference');
    }
  }

  DailyCheckInRecord read(String memberId, String day) {
    try {
      final raw = storage.prefs.getString('daily_check_in_$memberId');
      if (raw != null) {
        final record = DailyCheckInRecord.fromJson(jsonDecode(raw));
        if (record.day == day) return record;
      }
    } catch (_) {/* A damaged optional record must not block app startup. */}
    return DailyCheckInRecord(day: day);
  }

  Future<void> save(String memberId, DailyCheckInRecord record) async {
    if (!await storage.prefs
        .setString('daily_check_in_$memberId', jsonEncode(record.toJson()))) {
      throw StateError('Could not save check-in result');
    }
  }

  Future<DawnResult> check(CancelToken cancelToken) async {
    final timer =
        Timer(timeout, () => cancelToken.cancel('Check-in timed out'));
    try {
      return DawnParser.parse(await dio.get(newsUrl,
          cancelToken: cancelToken, followRedirects: false));
    } finally {
      timer.cancel();
    }
  }
}
