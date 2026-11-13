import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/transients/difference_image_seam.dart';

/// Production seam provider. Override in tests with a fake that records the
/// dispatched maps and returns canned candidate envelopes.
final differenceImageSeamProvider = Provider<DifferenceImageSeam>((ref) {
  return const BridgeDifferenceImageSeam();
});
