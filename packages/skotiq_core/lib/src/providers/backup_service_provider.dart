import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database_provider.dart';
import 'app_version_provider.dart';
import '../services/backup_service.dart';
import 'logging_service_provider.dart';
import 'sequence_repository_provider.dart';

final backupServiceProvider = Provider<BackupService>((ref) {
  final database = ref.watch(databaseProvider);
  final sequenceRepo = ref.watch(sequenceRepositoryProvider);
  final logger = ref.watch(loggingServiceProvider);
  final appVersion = ref.watch(appVersionProvider).version;

  return BackupService(
    database: database,
    sequenceRepository: sequenceRepo,
    logger: logger,
    appVersion: appVersion,
  );
});
