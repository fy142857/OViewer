import 'package:equatable/equatable.dart';

/// Logical size and normalized position in the unobstructed safe area.
class FloatingBackSettings extends Equatable {
  static const minSize = 32.0;
  static const maxSize = 72.0;
  final bool enabled;
  final double size, x, y;
  const FloatingBackSettings(
      {this.enabled = true, this.size = 48, this.x = 1, this.y = .7});

  bool get isValid =>
      size.isFinite &&
      size >= minSize &&
      size <= maxSize &&
      x.isFinite &&
      x >= 0 &&
      x <= 1 &&
      y.isFinite &&
      y >= 0 &&
      y <= 1;

  FloatingBackSettings copyWith(
          {bool? enabled, double? size, double? x, double? y}) =>
      FloatingBackSettings(
          enabled: enabled ?? this.enabled,
          size: size ?? this.size,
          x: x ?? this.x,
          y: y ?? this.y);

  factory FloatingBackSettings.fromJson(Object? json) {
    if (json is! Map) return const FloatingBackSettings();
    double read(String key, double fallback, double min, double max) {
      final value = json[key];
      return value is num && value.isFinite && value >= min && value <= max
          ? value.toDouble()
          : fallback;
    }

    return FloatingBackSettings(
        enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
        size: read('size', 48, minSize, maxSize),
        x: read('x', 1, 0, 1),
        y: read('y', .7, 0, 1));
  }

  Map<String, Object> toJson() =>
      {'enabled': enabled, 'size': size, 'x': x, 'y': y};
  @override
  List<Object> get props => [enabled, size, x, y];
}
