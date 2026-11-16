import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'linked_host.dart';
import 'backend_provider.dart';
import '../services/calibration/auto_calibration_notice.dart';
import '../services/calibration_service.dart';

final calibrationServiceProvider = Provider<CalibrationService>((ref) {
  ref.watch(backendProvider);
  return CalibrationService(
    ref,
    hostTools: ref.watch(linkedHostCalibrationToolsProvider),
  );
});

/// Provider for calibration settings, loaded from app settings.
final calibrationSettingsProvider =
    StateNotifierProvider<CalibrationSettingsNotifier, CalibrationSettings>((
      ref,
    ) {
      return CalibrationSettingsNotifier(
        ref,
        remote: ref.watch(linkedHostCalibrationToolsProvider),
      );
    });

/// Captured lights kept uncalibrated while auto-calibration is on. A change to
/// the calibration settings may remove the cause, so it ends the notice; the
/// next frame says whether it did.
final autoCalibrationNoticeProvider =
    StateNotifierProvider<AutoCalibrationNotice, UncalibratedFrames?>((ref) {
      final notice = AutoCalibrationNotice();
      ref.listen(calibrationSettingsProvider, (_, _) => notice.resolved());
      return notice;
    });
