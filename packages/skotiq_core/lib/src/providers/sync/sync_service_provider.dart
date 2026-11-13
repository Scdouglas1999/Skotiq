import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database_provider.dart';
import '../notification_router_provider.dart'
    show secretsStoreProvider;
import '../../services/sync/sync_service.dart';
import '../backup_service_provider.dart';
import '../logging_service_provider.dart';

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService(
    backupService: ref.watch(backupServiceProvider),
    settingsDao: ref.watch(settingsDaoProvider),
    secretsStore: ref.watch(secretsStoreProvider),
    logger: ref.watch(loggingServiceProvider),
  );
});
