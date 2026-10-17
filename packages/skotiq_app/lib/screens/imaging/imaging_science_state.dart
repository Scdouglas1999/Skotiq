import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

// autoDispose: annotation selection is page-scoped to the Imaging screen.
// Reset when the screen unmounts so a fresh visit starts with no selection.
final selectedAnnotationObjectProvider =
    StateProvider.autoDispose<CelestialObjectAnnotation?>((_) => null);

/// Provider for the annotation object that should be pulsed/highlighted.
/// Set when an object is selected from the sidebar list. The overlay reads this
/// to trigger a scale-up/down animation on the corresponding marker.
/// Value is the object ID, or null when no pulse is active.
// autoDispose: pulse state is transient animation metadata, must reset on
// screen teardown.
final annotationPulseObjectProvider =
    StateProvider.autoDispose<String?>((ref) => null);
