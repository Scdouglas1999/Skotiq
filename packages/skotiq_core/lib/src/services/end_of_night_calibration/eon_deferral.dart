import '../../database/daos/settings_dao.dart';
import '../../models/sequence/active_plan_owner.dart';
import 'eon_settings.dart';

/// Whether end-of-night calibration will follow a run that [owner] starts, so
/// the plan's closing warm-up waits for it. The scheduler's runs keep their
/// own warm-up (it ends the night itself), and a calibration run is the step's
/// own. A remote client never runs it; [settingsDao] is read only on the host.
Future<bool> endOfNightCalibrationFollows(
  ActivePlanOwner owner, {
  required bool Function() isRemote,
  required SettingsDao Function() settingsDao,
}) async {
  if (owner == ActivePlanOwner.calibration ||
      owner == ActivePlanOwner.autopilot) {
    return false;
  }
  if (isRemote()) return false;
  final settings = await EonSettings.load(settingsDao());
  return settings.enabled;
}
