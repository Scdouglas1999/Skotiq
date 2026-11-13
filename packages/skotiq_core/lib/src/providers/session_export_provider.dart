import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/session_export_service.dart';
import 'clock_provider.dart';
import 'database_provider.dart';

/// The one [SessionExportService], stamped with the user's clock: the
/// Analytics session export on this machine and the host's export endpoint
/// both use it.
final sessionExportServiceProvider = Provider<SessionExportService>((ref) {
  final clock = ref.watch(clockProvider);
  return SessionExportService(
    sessionsDao: ref.watch(sessionsDaoProvider),
    imagesDao: ref.watch(imagesDaoProvider),
    nowProvider: clock.now,
  );
});
