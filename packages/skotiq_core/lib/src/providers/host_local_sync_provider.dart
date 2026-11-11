import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';
import '../models/backend/host_mutation_event.dart';
import '../backend/remote_host.dart';
import 'backend_provider.dart';
import 'host_mutation_event_provider.dart';
import 'remote_sync_handler.dart';
import 'settings_provider.dart';
import 'web_server_provider.dart' show remoteAccessServing;

/// Keeps the desktop GUI aligned when a remote companion mutates state through
/// the embedded [HeadlessApiServer] REST surface or when native EventBus events
/// arrive while lazy services are not constructed.
///
/// Mobile clients use [remoteSessionSyncProvider] instead.
final hostLocalSyncProvider = Provider<void>((ref) {
  StreamSubscription<SkotiqEvent>? hubSub;
  StreamSubscription<SkotiqEvent>? backendSub;

  void teardown() {
    hubSub?.cancel();
    backendSub?.cancel();
    hubSub = null;
    backendSub = null;
  }

  ref.onDispose(teardown);

  void bindIfNeeded() {
    teardown();

    final backend = ref.read(diagnosticsBackendProvider);
    if (!backend.ownsDeviceBridge) {
      return;
    }

    // In-process hub: tablet REST mutations must refresh the desktop GUI even
    // when the native EventBus path is quiet. This does not require LAN access.
    final hub = ref.read(hostMutationEventHubProvider);
    hubSub = hub.stream.listen((event) {
      unawaited(applyRemoteSyncEvent(ref, event));
    });

    if (remoteAccessServing(ref)) {
      backendSub = backend.eventStream.listen((event) {
        if (event.eventType == hostStateChangedEventType) {
          return;
        }
        unawaited(applyRemoteSyncEvent(ref, event));
      });
    }
  }

  ref.listen<SkotiqBackend>(backendProvider, (_, __) => bindIfNeeded());
  ref.listen<AsyncValue<AppSettingsState>>(appSettingsProvider, (_, __) {
    bindIfNeeded();
  });

  bindIfNeeded();
});
