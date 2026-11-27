import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database_provider.dart';
import 'app_version_provider.dart';
import 'backend_provider.dart' show isRemoteClientProvider;
import '../services/backup_service.dart';
import 'logging_service_provider.dart';
import 'plate_solve_service_provider.dart';
import 'settings_provider.dart' show plateSolverPreferenceRows;

final backupServiceProvider = Provider<BackupService>((ref) {
  final database = ref.watch(databaseProvider);
  final logger = ref.watch(loggingServiceProvider);
  final appVersion = ref.watch(appVersionProvider).version;

  return BackupService(
    database: database,
    logger: logger,
    appVersion: appVersion,
    // The plate-solver settings are copies of this computer's native
    // preference. A backup carries none when it cannot be read (a restore
    // would set values nobody chose), nor on a client launch, whose
    // preference is its host's, linked or not.
    solverSettingRows: () async {
      if (ref.read(isRemoteClientProvider)) return const {};
      try {
        return plateSolverPreferenceRows(
          await ref.read(plateSolveServiceProvider).getConfig(),
        );
      } on Object catch (error) {
        logger.warning(
          'The plate-solver preference could not be read; the backup carries '
          'no solver settings, so restoring it leaves the solver as it is: '
          '$error',
          source: 'BackupService',
        );
        return const {};
      }
    },
  );
});
