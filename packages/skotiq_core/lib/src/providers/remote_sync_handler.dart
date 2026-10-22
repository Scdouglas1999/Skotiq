import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/bridge_event_mapper.dart' show tryBridgeEventFromCoreEvent;
import '../backend/network_backend.dart';
import '../models/backend/device_info.dart';
import '../models/backend/device_status.dart';
import '../models/backend/device_types.dart';
import '../models/backend/event_types.dart';
import '../models/backend/sequencer_status.dart';
import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../models/sequence/active_plan_owner.dart';
import '../models/sequence/sequence_models.dart';
import '../models/backend/host_mutation_event.dart';
import '../models/backend/host_runtime_update.dart';
import '../models/imaging/imaging_models.dart'
    show CapturePreviewSource, ExposureSettings;
import '../services/capture_preview_loader.dart'
    show capturePreviewPublisherProvider, capturedImageDataFromResult;
import '../services/imaging_service.dart'
    show currentImageProvider, exposureProgressProvider;
import '../services/logging_service.dart' show loggingServiceProvider;
import '../services/phd2_status_poll.dart';
import '../services/sequence_file_service.dart'
    show sequenceFileServiceProvider;
import '../utils/utc_timestamp.dart';
import 'database_provider.dart';
import 'backend_provider.dart';
import 'equipment_provider.dart';
import 'event_provider.dart' show eventHistoryProvider;
import 'device_heartbeat_health_provider.dart';
import 'equipment/device_type_registry.dart';
import 'framing_provider.dart';
import 'imaging_provider.dart' show exposureSettingsProvider;
import 'observing_list_provider.dart'
    show listedCatalogIdsProvider, observingListsProvider;
import 'profiles_provider.dart';
import 'provider_reader.dart';
import 'remote_sync_events.dart';
import 'runtime_mirror/client_runtime_mirror.dart';
import 'planning_provider.dart' show projectListProvider;
import 'scheduler_provider.dart'
    show
        integrationGoalsStreamProvider,
        schedulerPreviewDecisionProvider,
        targetConstraintsStreamProvider;
import 'sequence_provider.dart';
import 'sequence_stats_provider.dart'
    show
        currentRunIdProvider,
        sequenceRunsProvider,
        liveSequenceStatsProvider,
        SequenceRunStats;
import 'session_provider.dart';
import 'settings_provider.dart' show appSettingsProvider;
import 'target_progress_provider.dart'
    show allTargetProgressProvider, targetProgressProvider;

part 'remote_sync/equipment_mirror.dart';
part 'remote_sync/imaging_mirror.dart';
part 'remote_sync/guiding_mirror.dart';
part 'remote_sync/sequencer_mirror.dart';
part 'remote_sync/host_mutation.dart';
part 'remote_sync/device_mapping.dart';
part 'remote_sync/reader_access.dart';
part 'remote_sync/session_hydration.dart';

/// Applies a backend or host-sync event to Riverpod state so UI refreshes
/// without navigation. Used by remote companions ([NetworkBackend]), the
/// desktop host when remote access is enabled, and API mutation publishers.
Future<void> applyRemoteSyncEvent(
  Object reader,
  SkotiqEvent event, {
  NetworkBackend? networkBackend,
}) async {
  if (networkBackend != null &&
      !_isCurrentRemoteBackend(reader, networkBackend)) {
    return;
  }
  if (event.eventType == 'BackendReconnected' && networkBackend != null) {
    await hydrateRemoteSessionState(reader, networkBackend);
    return;
  }

  switch (event.category) {
    case EventCategory.system:
      await _applySystemSyncEvent(
        reader,
        event,
        networkBackend: networkBackend,
      );
      break;
    case EventCategory.equipment:
      _applyEquipmentEvent(reader, event, networkBackend: networkBackend);
      break;
    case EventCategory.guiding:
      await _applyGuidingEvent(reader, event, networkBackend: networkBackend);
      break;
    case EventCategory.sequencer:
      _applySequencerEvent(reader, event, networkBackend: networkBackend);
      break;
    case EventCategory.imaging:
      if (event.eventType == 'ImageCaptured' ||
          event.eventType == 'ImageSaved') {
        _invalidateHostCapturedImages(reader);
      }
      // Remote parity: the host-local capture path publishes
      // `currentImageProvider` via [CapturePreviewPublisher]; that path never
      // runs on a remote companion (NetworkBackend, no local executor), so the
      // dashboard's "current frame" hero tile would stay blank during a
      // host-run sequence. When the host reports a fresh frame, pull it over
      // the existing remoted JPEG path and publish it locally so the tile +
      // histogram/stats update exactly as they do on the host.
      //
      // `ImageReady` is the canonical "host has a freshly decoded frame"
      // event (carries width/height); `ImageSaved`/`ImageCaptured` are also
      // accepted so the tile still populates if the ready event is missed.
      if (networkBackend != null &&
          (event.eventType == 'ImageReady' ||
              event.eventType == 'ImageSaved' ||
              event.eventType == 'ImageCaptured')) {
        unawaited(_publishRemoteCurrentFrame(reader, networkBackend));
      }
      // Slave-only: mirror the master's per-frame exposure countdown onto the
      // camera card + exposure-progress dashboard. These imaging events drive
      // [cameraStateProvider.setExposing] / [exposureProgressProvider] exactly
      // as ImagingService does on the host (whose capture loop never runs on a
      // remote companion), so the slave's "Exposing" status and the remaining-
      // time countdown track the master frame-for-frame.
      if (networkBackend != null) {
        _applyExposureMirror(reader, event.eventType, event.data);
      }
      break;
    case EventCategory.safety:
    case EventCategory.polarAlignment:
    case EventCategory.job:
    case EventCategory.session:
    case EventCategory.catalog:
      // /// no remote-sync invalidations needed; these
      // categories are end-state notifications consumed by UI widgets
      // (toasts, progress badges) rather than caches.
      break;
  }
}

Future<void> _applySystemSyncEvent(
  Object reader,
  SkotiqEvent event, {
  NetworkBackend? networkBackend,
}) async {
  if (event.eventType == hostStateChangedEventType) {
    _applyHostMutation(reader, event.data);
    return;
  }
  if (event.eventType == hostRuntimeStateEventType) {
    final update = HostRuntimeUpdate.fromJson(event.data);
    if (networkBackend != null && update != null) {
      applyHostRuntimeUpdate(reader, update, networkBackend: networkBackend);
    }
    return;
  }

  switch (event.eventType) {
    case RemoteSyncEventTypes.sequenceUpdated:
      _invalidateSequenceLibrary(
        reader,
        sequenceId: event.data['sequenceId'] as int?,
      );
      break;
    case RemoteSyncEventTypes.profileChanged:
      _invalidateEquipmentSyncProviders(reader);
      break;
    case RemoteSyncEventTypes.framingTargetChanged:
      _applyFramingTargetChanged(reader, event);
      break;
    case RemoteSyncEventTypes.guiderState:
      if (networkBackend != null) {
        await _hydratePhd2GuiderState(reader, networkBackend);
      }
      break;
    case RemoteSyncEventTypes.deviceConnected:
      _applyDeviceConnectedFromSyncPayload(reader, event.data);
      break;
    case RemoteSyncEventTypes.deviceDisconnected:
      _applyDeviceDisconnectedFromSyncPayload(reader, event.data);
      break;
  }
}

/// Fetch the host's newest frame into this client's current image, as a frame
/// event from the host would. Coalesces with a fetch already running.
///
/// [hint] describes the frame the host announced; when the fetched frame has
/// its dimensions, it takes the host's saved path, target and capture settings,
/// which the last-frame endpoint does not carry.
void requestHostCurrentFrame(
  Object reader,
  NetworkBackend backend, {
  HostFrameHint? hint,
}) {
  final fetchState = _remoteFrameFetchStates[reader] ??=
      _RemoteFrameFetchState();
  fetchState.hint = hint;
  unawaited(_publishRemoteCurrentFrame(reader, backend));
}
