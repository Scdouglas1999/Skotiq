import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for cloud backup/sync (bundle-based push to a WebDAV target).
///
/// Deliberately minimal: configuration lives in the desktop settings UI
/// (server URL/username in app settings, password in the OS keyring), so
/// the headless surface only exposes what a remote couch client needs —
/// sync status and "push now". Pull/restore over the API already exists
/// via `/api/backup/upload-restore`.
class SyncHandlers {
  final ProviderContainer container;
  SyncHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);

  /// GET /api/sync/status — configured?, auto-push, last push, last error.
  Future<Response> handleGetStatus(Request request) async {
    _logger.info('[API] GET /api/sync/status', source: 'SyncHandlers');
    final service = container.read(syncServiceProvider);
    final status = await service.status();
    return jsonOk(status.toJson());
  }

  /// POST /api/sync/push — create a backup bundle and push it to the
  /// configured sync target. Fails with a structured error when sync is
  /// not configured or the upload fails.
  Future<Response> handlePushNow(Request request) async {
    _logger.info('[API] POST /api/sync/push', source: 'SyncHandlers');
    final service = container.read(syncServiceProvider);
    // Distinguish "not configured" (a client precondition) from a genuine
    // upload failure. Returning 500 for the former makes remote clients retry
    // a transient-looking server error instead of prompting the operator to
    // configure a sync server first.
    final status = await service.status();
    if (!status.configured) {
      throw HandlerFailure(
        code: 'sync_not_configured',
        message:
            'Cloud sync is not configured; set a server URL in sync settings first.',
        statusCode: 409,
      );
    }
    final result = await service.pushNow();
    if (result.success) {
      return jsonOk({
        'status': 'pushed',
        'remotePath': result.remotePath,
        'sizeBytes': result.sizeBytes,
        'timestamp': result.timestamp.millisecondsSinceEpoch,
      });
    }
    _logger.error(
      '[API] Sync push failed: ${result.errorMessage}',
      source: 'SyncHandlers',
    );
    throw HandlerFailure(
      code: 'sync_push_failed',
      message: result.errorMessage ?? 'Cloud sync push failed',
    );
  }
}
