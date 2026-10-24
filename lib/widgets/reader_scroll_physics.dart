import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// PageView supplies its own PageScrollPhysics above the provided physics.
/// Scale its inherited spring, preserving damping ratio and drag behaviour.
class ReaderScrollPhysics extends ScrollPhysics {
  const ReaderScrollPhysics({super.parent});

  @override
  ReaderScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      ReaderScrollPhysics(parent: buildParent(ancestor));

  @override
  SpringDescription get spring {
    final original = super.spring;
    return SpringDescription(
      mass: original.mass,
      stiffness: original.stiffness * 4,
      damping: original.damping * 2,
    );
  }
}
