import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the run in progress, or the last one, handed its closing Warm
/// Camera step to end-of-night calibration. Set when a run starts.
final shutdownWarmUpDeferredProvider = StateProvider<bool>((ref) => false);
