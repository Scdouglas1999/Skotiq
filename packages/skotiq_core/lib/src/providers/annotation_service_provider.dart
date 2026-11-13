import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/skotiq_backend.dart';
import '../models/imaging/imaging_models.dart';
import 'backend_provider.dart';
import 'imaging_provider.dart';
import '../services/imaging_service.dart';
import '../services/annotation_service.dart';

final annotationServiceProvider = Provider<AnnotationService>((ref) {
  final service = AnnotationService(ref, attachListeners: false);
  ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
    service.handleBackendChanged(previous, next);
  });
  ref.listen<CapturedImageData?>(currentImageProvider, (previous, next) {
    service.handleCurrentImageChanged(previous, next);
  });
  ref.listen<ImageStats?>(lastImageStatsProvider, (previous, next) {
    service.handleImageStatsChanged(previous, next);
  });
  return service;
});
