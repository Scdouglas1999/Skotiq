import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database_provider.dart';
import 'app_version_provider.dart';
import 'backend_provider.dart' show isRemoteModeProvider;
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
    // preference. A backup without it carries the stored rows; so does a
    // linked client's, whose preference is the host's.
    settingsOverlay: () async {
      if (ref.read(isRemoteModeProvider)) return const {};
      try {
        return plateSolverPreferenceRows(
          await ref.read(plateSolveServiceProvider).getConfig(),
        );
      } on Object catch (error) {
        logger.debug(
          'Plate-solver preference unavailable; the backup carries the '
          'stored solver settings: $error',
          source: 'BackupService',
        );
        return const {};
      }
    },
  );
});
