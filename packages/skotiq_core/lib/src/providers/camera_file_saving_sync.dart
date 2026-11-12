import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/logging_service.dart';
import 'settings_provider.dart';
import 'backend_provider.dart';

/// Keeps the native save's camera-file choice equal to the
/// `cameraFileSaving` setting, from host start-up on: a manual capture saves
/// outside any run, so a push at run start would come too late for it. Runs
/// on hosts only (see `alwaysOnServices`).
final cameraFileSavingSyncProvider = Provider<void>((ref) {
  ref.listen<String?>(
    appSettingsProvider.select((s) => s.valueOrNull?.cameraFileSaving),
    (_, saving) async {
      if (saving == null) return;
      try {
        await ref
            .read(sequencerBackendProvider)
            .sequencerSetCameraFileSaving(saving);
      } catch (e) {
        ref
            .read(loggingServiceProvider)
            .warning(
              'Could not apply the camera-file setting ($saving): $e',
              source: 'CameraFileSaving',
            );
      }
    },
    fireImmediately: true,
  );
});
