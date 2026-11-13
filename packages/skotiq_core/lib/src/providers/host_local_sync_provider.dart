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
import '../models/backend/backend_types.dart';
import '../settings/app_settings_state.g.dart';

/// Keeps the host's own window in step with what happens through its server:
/// a linked client changing state over the API, and native events that arrive
/// while the service that would handle them is not built.
///
/// A linked client follows its host with [remoteSessionSyncProvider].
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
      applyHostLocalSyncEvent(ref.container, event);
    });

    if (remoteAccessServing(ref)) {
      backendSub = backend.eventStream.listen((event) {
        if (event.eventType == hostStateChangedEventType) {
          return;
        }
        applyHostLocalSyncEvent(ref.container, event);
      });
    }
  }

  ref.listen<SkotiqBackend>(backendProvider, (_, __) => bindIfNeeded());
  ref.listen<AsyncValue<AppSettingsState>>(appSettingsProvider, (_, __) {
    bindIfNeeded();
  });

  bindIfNeeded();
});

/// Keeps the host's camera card and exposure countdown on every exposure of
/// its camera that its capture service did not start: the frames of a run, a
/// linked client's snapshot, an API capture. A daemon runs it too, so what it
/// tells its clients ([ExposureChannel]) is what a host window shows.
final hostExposureFollowProvider = Provider<void>((ref) {
  final backend = ref.watch(diagnosticsBackendProvider);
  if (!backend.ownsDeviceBridge) return;
  final events = backend.eventStream.listen((event) {
    if (event.category != EventCategory.imaging) return;
    followHostCameraExposure(ref.container, event);
  });
  ref.onDispose(events.cancel);
});
