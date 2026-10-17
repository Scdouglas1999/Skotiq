part of '../science_processing_service.dart';

final scienceProcessingServiceProvider = Provider<ScienceProcessingService>((
  ref,
) {
  return ScienceProcessingService(ref);
});
