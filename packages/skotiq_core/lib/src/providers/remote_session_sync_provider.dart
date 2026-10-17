import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../services/logging_service.dart';
import 'backend_provider.dart';
import 'remote_sync_handler.dart';

const _logSource = 'RemoteSessionSync';

/// Keeps companion UI state aligned with the imaging host when connected via
/// [NetworkBackend]. Without hydration, mobile shows local SQLite profiles and
/// disconnected device chips even though the desktop rig is live.
final remoteSessionSyncProvider = Provider<void>((ref) {
  StreamSubscription<SkotiqEvent>? eventSub;
  Timer? pollTimer;
  var generation = 0;
  var hydrationInFlight = false;
  var hydrationPending = false;

  void teardown() {
    generation++;
    eventSub?.cancel();
    pollTimer?.cancel();
    eventSub = null;
    pollTimer = null;
    hydrationInFlight = false;
    hydrationPending = false;
  }

  late final void Function(NetworkBackend backend) requestHydration;
  requestHydration = (backend) {
    if (!identical(ref.read(backendProvider), backend)) return;
    // Terminal backend state (auth rejected, version/identity mismatch):
    // every request in the hydration fan-out can only fail — and for a
    // dead token each failure feeds the server's auth-failure limiter.
    // Stay quiet until an explicit reconnect moves the state out of
    // `error`. `==` rather than `isAuthTokenRejected` so this also covers
    // the other terminal modes.
    if (backend.connectionState == BackendConnectionState.error) return;
    if (hydrationInFlight) {
      hydrationPending = true;
      return;
    }
    final requestGeneration = generation;
    hydrationInFlight = true;
    unawaited(
      _hydrate(ref, backend).whenComplete(() {
        if (requestGeneration != generation) return;
        hydrationInFlight = false;
        if (hydrationPending) {
          hydrationPending = false;
          requestHydration(backend);
        }
      }),
    );
  };

  ref.onDispose(teardown);

  ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
    teardown();
    if (next is! NetworkBackend) {
      return;
    }

    requestHydration(next);

    eventSub = next.eventStream.listen((event) {
      if (event.eventType == 'BackendReconnected') {
        requestHydration(next);
      } else {
        unawaited(applyRemoteSyncEvent(ref, event, networkBackend: next));
      }
    });

    pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      requestHydration(next);
    });
  }, fireImmediately: true);
});

Future<void> _hydrate(Ref ref, NetworkBackend backend) async {
  final logger = ref.read(loggingServiceProvider);

  try {
    await hydrateRemoteSessionState(ref, backend);
    if (!identical(ref.read(backendProvider), backend)) return;
    logger.info('Hydrated remote session from host', source: _logSource);
  } catch (e, stackTrace) {
    logger.error(
      'Remote session hydration failed: $e',
      source: _logSource,
      fields: {'stackTrace': '$stackTrace'},
    );
    developer.log(
      'Remote session hydration failed: $e',
      name: _logSource,
      level: 1000,
      error: e,
      stackTrace: stackTrace,
    );
  }
}
