enum CheckInStatus {
  signedOut,
  pending,
  running,
  confirmed,
  unconfirmed,
  failed
}

/// Only server-confirmed Dawn events count as a successful check-in.
class DailyCheckInRecord {
  final String day;
  final CheckInStatus status;
  final int automaticAttempts;
  final DateTime? lastAttempt;
  final DateTime? nextAttempt;
  final String rewards;
  final bool notified;

  const DailyCheckInRecord(
      {required this.day,
      this.status = CheckInStatus.pending,
      this.automaticAttempts = 0,
      this.lastAttempt,
      this.nextAttempt,
      this.rewards = '',
      this.notified = false});

  Map<String, dynamic> toJson() => {
        'day': day,
        'status': status.name,
        'attempts': automaticAttempts,
        'last': lastAttempt?.toIso8601String(),
        'next': nextAttempt?.toIso8601String(),
        'rewards': rewards,
        'notified': notified,
      };

  factory DailyCheckInRecord.fromJson(Map<String, dynamic> json) {
    var status = CheckInStatus.values.byName(json['status'] as String);
    // An interrupted request is not proof of success; preserve its retry budget.
    if (status == CheckInStatus.running) status = CheckInStatus.unconfirmed;
    return DailyCheckInRecord(
        day: json['day'] as String,
        status: status,
        automaticAttempts: json['attempts'] as int,
        lastAttempt: DateTime.tryParse(json['last'] as String? ?? ''),
        nextAttempt: DateTime.tryParse(json['next'] as String? ?? ''),
        rewards: json['rewards'] as String? ?? '',
        notified: json['notified'] == true);
  }
}

class DailyCheckInState {
  final bool enabled;
  final String? memberId;
  final DailyCheckInRecord record;
  final bool storageFailed;
  const DailyCheckInState(
      {required this.enabled,
      required this.record,
      this.memberId,
      this.storageFailed = false});
  CheckInStatus get status =>
      memberId == null ? CheckInStatus.signedOut : record.status;
  bool get needsDialog =>
      memberId != null && status == CheckInStatus.confirmed && !record.notified;
}

String checkInDay(DateTime time) =>
    time.toUtc().toIso8601String().substring(0, 10);
