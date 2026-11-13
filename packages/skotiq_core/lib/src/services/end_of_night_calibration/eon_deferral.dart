import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sequence/active_plan_owner.dart';
import '../../providers/backend_provider.dart';
import '../../providers/database_provider.dart';
import 'eon_settings.dart';
import '../../backend/remote_host.dart';

/// Whether end-of-night calibration will follow a run that [owner] starts, so
/// the plan's closing warm-up waits for it. The scheduler's runs keep their
/// own warm-up (it ends the night itself), and a calibration run is the step's
/// own.
Future<bool> endOfNightCalibrationFollows(
  Ref ref,
  ActivePlanOwner owner,
) async {
  if (owner == ActivePlanOwner.calibration ||
      owner == ActivePlanOwner.autopilot) {
    return false;
  }
  if (ref.read(backendProvider).remoteHost != null) return false;
  final settings = await EonSettings.load(ref.read(settingsDaoProvider));
  return settings.enabled;
}
