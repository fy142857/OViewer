import 'dart:async';
import '../../models/gallery_source.dart';
import 'package:equatable/equatable.dart';

abstract class DownloadEvent extends Equatable {
  const DownloadEvent();
  @override
  List<Object?> get props => [];
}

class LoadDownloads extends DownloadEvent {}

class StartDownload extends DownloadEvent {
  final int gid;
  final String token;
  final String title;
  final String thumbUrl;
  final int totalPages;
  final GallerySource? source;
  final Completer<void>? completer;

  const StartDownload({
    required this.gid,
    required this.token,
    required this.title,
    required this.thumbUrl,
    required this.totalPages,
    this.source,
    this.completer,
  });

  @override
  List<Object?> get props => [gid];
}

class PauseDownload extends DownloadEvent {
  final String id;
  const PauseDownload(this.id);
  @override
  List<Object?> get props => [id];
}

class ResumeDownload extends DownloadEvent {
  final String id;
  const ResumeDownload(this.id);
  @override
  List<Object?> get props => [id];
}

class DeleteDownload extends DownloadEvent {
  final String id;
  const DeleteDownload(this.id);
  @override
  List<Object?> get props => [id];
}
