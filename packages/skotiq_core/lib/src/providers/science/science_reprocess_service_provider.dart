import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database_provider.dart';
import '../../services/science/science_reprocess_service.dart';
import '../logging_service_provider.dart';
import 'science_processing_service_provider.dart';

final scienceReprocessServiceProvider = Provider<ScienceReprocessService>((
  ref,
) {
  return ScienceReprocessService(
    images: () => ref.read(imagesDaoProvider),
    science: () => ref.read(scienceDaoProvider),
    pipeline: () => ref.read(scienceProcessingServiceProvider),
    logger: () => ref.read(loggingServiceProvider),
  );
});
