import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../core/services/offline_download_coordinator.dart';
import '../../models/offline_book.dart';
import 'download_event.dart';
import 'download_state.dart';

/// Presentation adapter. The application coordinator owns every worker.
class DownloadBloc extends Bloc<DownloadEvent, DownloadState> {
  final OfflineDownloadCoordinator coordinator;
  late final StreamSubscription<void> _changes;
  int _loadGeneration = 0;
  DownloadBloc(this.coordinator) : super(const DownloadState()) {
    _changes = coordinator.changes.listen((_) {
      if (!isClosed) add(LoadDownloads());
    });
    on<LoadDownloads>((event, emit) async {
      final generation = ++_loadGeneration;
      try {
        await coordinator.initialize();
        final tasks = await coordinator.repository.all();
        if (generation == _loadGeneration && !emit.isDone) {
          emit(DownloadState(status: DownloadListStatus.loaded, tasks: tasks));
        }
      } catch (_) {
        if (generation == _loadGeneration && !emit.isDone) {
          emit(state.copyWith(
              status: DownloadListStatus.error, errorMessage: 'storage'));
        }
      }
    });
    on<StartDownload>((event, emit) async {
      try {
        if (event.source == null) throw const OfflineFailure('source_required');
        await coordinator.enqueue(
            OfflineKey(event.source!, event.gid, event.token),
            event.title,
            event.totalPages);
        event.completer?.complete();
        add(LoadDownloads());
      } catch (error) {
        final code = error is OfflineFailure ? error.code : 'storage';
        emit(state.copyWith(errorMessage: code));
        event.completer?.completeError(OfflineFailure(code));
      }
    });
    on<PauseDownload>(
        (event, emit) => _run(() => coordinator.pause(event.id), emit));
    on<ResumeDownload>(
        (event, emit) => _run(() => coordinator.resume(event.id), emit));
    on<DeleteDownload>(
        (event, emit) => _run(() => coordinator.delete(event.id), emit));
  }
  Future<void> _run(
      Future<void> Function() action, Emitter<DownloadState> emit) async {
    try {
      await action();
      if (!isClosed) add(LoadDownloads());
    } catch (error) {
      if (!emit.isDone)
        emit(state.copyWith(
            errorMessage: error is OfflineFailure ? error.code : 'storage'));
    }
  }

  @override
  Future<void> close() async {
    await _changes.cancel();
    await super.close();
  }
}
