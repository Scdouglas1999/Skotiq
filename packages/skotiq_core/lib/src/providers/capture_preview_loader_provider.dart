import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'backend_provider.dart';
import '../services/capture_preview_loader.dart';

final capturePreviewPublisherProvider = Provider<CapturePreviewPublisher>((
  ref,
) {
  ref.watch(backendProvider);
  final publisher = CapturePreviewPublisher();
  ref.onDispose(publisher.cancelPending);
  return publisher;
});
