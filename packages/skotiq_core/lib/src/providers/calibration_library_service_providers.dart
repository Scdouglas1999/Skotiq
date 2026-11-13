import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../backend/remote_host.dart';
import '../backend/roles/host_data/calibration_library.dart';
import 'database_provider.dart';
import 'backend_provider.dart';
import '../services/constellation/hub_credentials.dart';
import '../services/calibration/shared_calibration_library.dart';
import '../utils/skotiq_data_directory.dart';
import '../services/calibration_library_service.dart';

/// The calibration library of whichever machine is the imaging host: this
/// process's own ([calibrationLibraryServiceProvider]), or the linked host's.
final calibrationLibraryProvider = Provider<CalibrationLibrary>(
  (ref) =>
      ref.watch(backendProvider).remoteHost?.calibrationLibrary ??
      ref.watch(calibrationLibraryServiceProvider),
);

/// The calibration library in this process's database.
final calibrationLibraryServiceProvider = Provider<CalibrationLibraryService>((
  ref,
) {
  // One service per host: its work goes stale when the host changes.
  ref.watch(backendProvider);
  final settings = ref.watch(settingsDaoProvider);
  final service = CalibrationLibraryService(
    db: ref.watch(databaseProvider),
    flatLibraryDao: ref.watch(flatLibraryDaoProvider),
    tagsDao: ref.watch(calibrationTagsDaoProvider),
    ref: ref,
    // Fold ranked masters shared on the configured Constellation hub into
    // the local ranking, and download-on-accept. Reuses the same settings-backed
    // hub credentials Pillar C resolves; a no-hub config simply yields no remote
    // candidates.
    remoteLibrary: HubCalibrationLibrary(
      credentialsResolver: () => resolveConstellationCredentials(settings),
    ),
    sharedMasterDirResolver: () async {
      final dir = await resolveSkotiqDataDirectory();
      return p.join(dir.path, 'shared_calibration');
    },
  );
  return service;
});
