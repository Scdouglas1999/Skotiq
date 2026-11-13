import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/logging_service.dart';

final loggingServiceProvider = Provider<LoggingService>((ref) {
  final service = LoggingService();
  unawaited(service.ensureInitialized());
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});
