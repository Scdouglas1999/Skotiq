import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database_provider.dart';
import 'dark_library_provider.dart';
import '../services/master_accumulation_service.dart';
import 'flat_library_service_provider.dart';
import 'logging_service_provider.dart';
import 'post_session_seam_provider.dart';

final masterAccumulationServiceProvider = Provider<MasterAccumulationService>((
  ref,
) {
  return MasterAccumulationService(
    mastersDao: ref.watch(integratedMastersDaoProvider),
    darkLibrary: ref.watch(darkLibraryServiceProvider),
    flatLibrary: ref.watch(flatLibraryServiceProvider),
    seam: ref.watch(postSessionSeamProvider),
    darkTolerances: ref.watch(darkLibraryMatchTolerancesProvider),
    logger: ref.watch(loggingServiceProvider),
  );
});
