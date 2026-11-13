import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/logging_service.dart';

final loggingServiceProvider = Provider<LoggingService>((ref) {
  final service = LoggingService();
  unawaited(service.ensureInitialized());
  Log.attach(service);
  ref.onDispose(() {
    Log.detach(service);
    unawaited(service.dispose());
  });
  return service;
});

/// Runs [emit] with the container's logger and never throws: a container that
/// is shutting down cannot hand its logger out, and a diagnostic must not mask
/// the fault it was reporting. The refusal itself goes to the process log.
void logSafely(Ref ref, void Function(LoggingService logger) emit) {
  try {
    emit(ref.read(loggingServiceProvider));
  } on Object catch (e) {
    Log.warning(
      'A log entry could not be recorded',
      source: 'LoggingService',
      error: e,
    );
  }
}
