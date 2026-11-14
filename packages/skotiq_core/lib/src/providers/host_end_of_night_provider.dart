import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/end_of_night_calibration/eon_service.dart';

/// On a remote client: the imaging host's end-of-night calibration status, or
/// null before the host has reported one.
///
/// The calibration runs on the host. A client mirrors it from the host's
/// `endOfNight` runtime channel, so whoever is driving the night sees the host waiting
/// for a cap and can confirm or skip it.
final hostEndOfNightStatusProvider = StateProvider<EonStatus?>((ref) => null);
