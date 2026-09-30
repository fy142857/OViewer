import 'package:flutter_bloc/flutter_bloc.dart';
import '../../repositories/history_repository.dart';
import 'history_event.dart';
import 'history_state.dart';

class HistoryBloc extends Bloc<HistoryEvent, HistoryState> {
  final HistoryRepository _repository;

  HistoryBloc(this._repository) : super(const HistoryState()) {
    on<LoadHistory>(_onLoad);
    on<DeleteHistoryEntry>(_onDelete);
    on<ClearAllHistory>(_onClearAll);
  }

  Future<void> _onLoad(
    LoadHistory event,
    Emitter<HistoryState> emit,
  ) async {
    // Returning to History refreshes local data without replacing the current
    // list (or a previously loaded empty view) with a full-page spinner.
    if (state.status == HistoryStatus.initial) {
      emit(state.copyWith(status: HistoryStatus.loading));
    }
    try {
      final entries = await _repository.getAllHistory();
      emit(state.copyWith(
        status: HistoryStatus.loaded,
        entries: entries,
      ));
    } catch (e) {
      emit(state.copyWith(
        status: HistoryStatus.error,
        errorMessage: e.toString(),
      ));
    }
  }

  Future<void> _onDelete(
    DeleteHistoryEntry event,
    Emitter<HistoryState> emit,
  ) async {
    await _repository.deleteHistory(event.gid);
    add(LoadHistory());
  }

  Future<void> _onClearAll(
    ClearAllHistory event,
    Emitter<HistoryState> emit,
  ) async {
    await _repository.clearAllHistory();
    emit(state.copyWith(
      status: HistoryStatus.loaded,
      entries: [],
    ));
  }
}
