import 'package:equatable/equatable.dart';
import '../../models/offline_book.dart';

enum DownloadListStatus { initial, loading, loaded, error }

class DownloadState extends Equatable {
  final DownloadListStatus status;
  final List<OfflineBook> tasks;
  final String? errorMessage;
  final Set<String> resumingIds;
  const DownloadState(
      {this.status = DownloadListStatus.initial,
      this.tasks = const [],
      this.resumingIds = const {},
      this.errorMessage});
  DownloadState copyWith(
          {DownloadListStatus? status,
          List<OfflineBook>? tasks,
          Set<String>? resumingIds,
          String? errorMessage}) =>
      DownloadState(
          status: status ?? this.status,
          tasks: tasks ?? this.tasks,
          resumingIds: resumingIds ?? this.resumingIds,
          errorMessage: errorMessage);
  @override
  List<Object?> get props => [status, tasks, errorMessage, resumingIds];
}
