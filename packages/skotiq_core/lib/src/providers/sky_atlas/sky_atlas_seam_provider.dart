import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/sky_atlas/sky_atlas_seam.dart';

/// Production seam provider. Override in tests with a fake that records the
/// dispatched maps and returns canned results.
final skyAtlasSeamProvider = Provider<SkyAtlasSeam>((ref) {
  return const BridgeSkyAtlasSeam();
});
