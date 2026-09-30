import 'dart:async';
import 'package:equatable/equatable.dart';

abstract class SettingsEvent extends Equatable {
  const SettingsEvent();
  @override
  List<Object?> get props => [];
}

class LoadSettings extends SettingsEvent {}

class UpdateThemeMode extends SettingsEvent {
  final int mode;
  const UpdateThemeMode(this.mode);
  @override
  List<Object?> get props => [mode];
}

class UpdateReadingMode extends SettingsEvent {
  final int mode;
  const UpdateReadingMode(this.mode);
  @override
  List<Object?> get props => [mode];
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
