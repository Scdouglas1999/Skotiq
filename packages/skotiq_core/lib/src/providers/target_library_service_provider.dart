import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'async_scope.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'linked_host.dart';
import 'logging_service_provider.dart';
import '../services/target_library_service.dart';

final targetLibraryServiceProvider = Provider<TargetLibraryService>((ref) {
  ref.watch(backendProvider);
  final hostRecords = ref.watch(linkedHostImagingRecordsProvider);
  return TargetLibraryService(
    host: ref.providerBackendScope(),
    hostRecords: hostRecords,
    targetsDao: () => ref.read(targetsDaoProvider),
    logger: () => ref.read(loggingServiceProvider),
    onLibraryChanged: () {
      ref.invalidate(allDbTargetsProvider);
      ref.invalidate(favoriteDbTargetsProvider);
    },
  );
});
