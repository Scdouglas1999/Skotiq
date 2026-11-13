import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import 'flat_wizard_provider.dart';
import 'settings_provider.dart';
import '../services/flat_wizard_service.dart';

/// Provider for FlatWizardService.
///
/// Re-watches `flatWizardProvider` so a
/// settings change (min/max exposure, image download timeout, max iterations)
/// rebuilds the service with the new values instead of being silently ignored.
final flatWizardServiceProvider = Provider<FlatWizardService>((ref) {
  final backend = ref.watch(backendProvider.select((b) => b));
  final settings = ref.watch(
    flatWizardProvider.select((s) => s.globalSettings),
  );
  final attempts = ref.watch(
    appSettingsProvider.select(
      (s) => s.valueOrNull?.flatCalibrationAttempts ?? 20,
    ),
  );
  return FlatWizardService.fromSettings(
    backend,
    settings,
    calibrationAttempts: attempts,
  );
});
