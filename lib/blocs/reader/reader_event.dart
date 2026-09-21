import 'package:equatable/equatable.dart';

abstract class ReaderEvent extends Equatable {
  const ReaderEvent();
  @override
  List<Object?> get props => [];
}

class LoadReaderImages extends ReaderEvent {
  final int gid;
  final String token;
  final int? initialPage;
  const LoadReaderImages({
    required this.gid,
    required this.token,
    this.initialPage,
  });
  @override
  List<Object?> get props => [gid, token, initialPage];
}

class LoadImageAtIndex extends ReaderEvent {
  final int index;
  const LoadImageAtIndex(this.index);
  @override
  List<Object?> get props => [index];
}

class LoadThumbnailAtIndex extends ReaderEvent {
  final int index;
  final bool retry;
  const LoadThumbnailAtIndex(this.index, {this.retry = false});
  @override
  List<Object?> get props => [index, retry];
}

class PageChanged extends ReaderEvent {
  final int page;
  const PageChanged(this.page);
  @override
  List<Object?> get props => [page];
}

class ToggleReaderUI extends ReaderEvent {}

class ChangeReadingMode extends ReaderEvent {
  final int mode; // 0=LR, 1=RL, 2=vertical
  const ChangeReadingMode(this.mode);
  @override
  List<Object?> get props => [mode];
}

/// Retry loading an image using the nl (network location) key
/// to request an alternate server.
class RetryImageAtIndex extends ReaderEvent {
  final int index;
  const RetryImageAtIndex(this.index);
  @override
  List<Object?> get props => [index];
}
