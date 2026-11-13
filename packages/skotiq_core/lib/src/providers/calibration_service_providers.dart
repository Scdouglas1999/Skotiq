import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import '../backend/remote_host.dart';
import '../services/calibration_service.dart';

final calibrationServiceProvider = Provider<CalibrationService>((ref) {
  ref.watch(backendProvider);
  return CalibrationService(ref);
});

/// Provider for calibration settings, loaded from app settings.
final calibrationSettingsProvider =
    StateNotifierProvider<CalibrationSettingsNotifier, CalibrationSettings>((
      ref,
    ) {
      final backend = ref.watch(backendProvider);
      return CalibrationSettingsNotifier(
        ref,
        remote: backend.remoteHost?.calibrationTools,
      );
    });
