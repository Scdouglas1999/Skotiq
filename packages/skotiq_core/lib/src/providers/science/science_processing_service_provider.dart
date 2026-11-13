import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/science/science_processing_service.dart';

final scienceProcessingServiceProvider = Provider<ScienceProcessingService>((
  ref,
) {
  return ScienceProcessingService(ref);
});
