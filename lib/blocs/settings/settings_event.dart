import '../../models/reader_page_layout.dart';
import 'dart:async';
import 'package:equatable/equatable.dart';

abstract class SettingsEvent extends Equatable {
  const SettingsEvent();
  @override
  List<Object?> get props => [];
}

class LoadSettings extends SettingsEvent {}

/// A patch, merged when dequeued, so concurrent position/size saves do not
/// overwrite one another with an old snapshot of the other fields.
class UpdateFloatingBack extends SettingsEvent {
  final bool? enabled;
  final double? size, x, y;
  final Completer<void> completer;
  const UpdateFloatingBack(this.completer,
      {this.enabled, this.size, this.x, this.y});
  @override
  List<Object?> get props => [enabled, size, x, y, completer];
}

class NetworkPreparationChanged extends SettingsEvent {}

class UpdateThemeMode extends SettingsEvent {
  final int mode;
  const UpdateThemeMode(this.mode);
  @override
  List<Object?> get props => [mode];
}

class UpdateReaderSpreadAlignment extends SettingsEvent {
  final ReaderSpreadAlignment alignment;
  const UpdateReaderSpreadAlignment(this.alignment);
  @override
  List<Object?> get props => [alignment];
}

class UpdateReaderPageTransition extends SettingsEvent {
  final ReaderPageTransition value;
  final Completer<void> completer;
  const UpdateReaderPageTransition(this.value, this.completer);
  @override
  List<Object?> get props => [value];
}

class UpdateReaderVolumeKeys extends SettingsEvent {
  final bool enabled;
  final Completer<void> completer;
  const UpdateReaderVolumeKeys(this.enabled, this.completer);
  @override
  List<Object?> get props => [enabled];
}

class UpdateReaderPageLayout extends SettingsEvent {
  final ReaderPageLayout layout;
  const UpdateReaderPageLayout(this.layout);
  @override
  List<Object?> get props => [layout];
}

class UpdateReadingMode extends SettingsEvent {
  final int mode;
  const UpdateReadingMode(this.mode);
  @override
  List<Object?> get props => [mode];
}

class UpdateReaderPreloadCount extends SettingsEvent {
  final int count;
  final Completer<void>? completer;
  const UpdateReaderPreloadCount(this.count, {this.completer});
  @override
  List<Object?> get props => [count];
}

class UpdateDisplayMode extends SettingsEvent {
  final int mode;
  const UpdateDisplayMode(this.mode);
  @override
  List<Object?> get props => [mode];
}

class UpdateProxy extends SettingsEvent {
  final String? proxyUrl;
  const UpdateProxy(this.proxyUrl);
  @override
  List<Object?> get props => [proxyUrl];
}

class ToggleAutoProxy extends SettingsEvent {
  final bool enabled;
  const ToggleAutoProxy(this.enabled);
  @override
  List<Object?> get props => [enabled];
}

class UpdateCacheLimit extends SettingsEvent {
  final int mb;
  final Completer<void>? completer;
  const UpdateCacheLimit(this.mb, {this.completer});
  @override
  List<Object?> get props => [mb];
}

class ToggleSiteMode extends SettingsEvent {
  final bool useExHentai;
  const ToggleSiteMode(this.useExHentai);
  @override
  List<Object?> get props => [useExHentai];
}

class SyncMyTags extends SettingsEvent {}

class UpdateLocale extends SettingsEvent {
  final String locale;
  const UpdateLocale(this.locale);
  @override
  List<Object?> get props => [locale];
}
