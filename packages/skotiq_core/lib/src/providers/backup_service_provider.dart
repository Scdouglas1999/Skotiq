import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database_provider.dart';
import 'app_version_provider.dart';
import 'backend_provider.dart' show isRemoteModeProvider;
import '../services/backup_service.dart';
import 'logging_service_provider.dart';
import 'plate_solve_service_provider.dart';
import 'settings_provider.dart'
    show plateSolverPreferenceRows, reportedPlateSolverPreference;

final backupServiceProvider = Provider<BackupService>((ref) {
  final database = ref.watch(databaseProvider);
  final logger = ref.watch(loggingServiceProvider);
  final appVersion = ref.watch(appVersionProvider).version;

  return BackupService(
    database: database,
    logger: logger,
    appVersion: appVersion,
    // The plate-solver settings are copies of this computer's native
    // preference. A linked client's backup carries the stored rows, since
    // its preference is the host's.
    settingsOverlay: () async {
      if (ref.read(isRemoteModeProvider)) return const {};
      return plateSolverPreferenceRows(
        await reportedPlateSolverPreference(
          ref.read(plateSolveServiceProvider),
          source: 'BackupService',
        ),
      );
    },
  );
});
