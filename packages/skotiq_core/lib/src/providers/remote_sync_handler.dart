import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import '../backend/skotiq_backend.dart';
import '../backend/bridge_event_mapper.dart' show tryBridgeEventFromCoreEvent;
import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../models/backend/host_mutation_event.dart';
import '../models/backend/host_runtime_update.dart';
import '../models/imaging/imaging_models.dart'
    show CapturePreviewSource, ExposureSettings, FramePurpose;
import '../services/device_service_lifecycle.dart';
import '../services/capture_preview_loader.dart'
    show capturedImageDataFromResult;
import '../services/imaging_service.dart'
    show currentImageProvider, exposureProgressProvider;
import '../utils/device_id.dart' show kPhd2CanonicalId, kPhd2DisplayName;
import '../utils/utc_timestamp.dart';
import 'current_frame_analysis_provider.dart' show hostFrameSolvesProvider;
import 'database_provider.dart';
import 'host_settings/host_settings_providers.dart'
    show hostSettingsStoreProvider;
import 'backend_provider.dart';
import 'equipment_provider.dart';
import 'event_provider.dart' show eventHistoryProvider;
import 'guiding_provider.dart' show guidingStopReasonProvider;
import 'imaging_provider.dart' show exposureSettingsProvider;
import 'observing_list_provider.dart'
    show listedCatalogIdsProvider, observingListsProvider;
import 'profiles_provider.dart';
import 'provider_reader.dart';
import 'runtime_mirror/channels/device_slot_channel.dart'
    show mirrorDevicesOfOlderHost;
import 'runtime_mirror/client_runtime_mirror.dart';
import 'planning_provider.dart' show projectListProvider;
import 'scheduler_provider.dart'
    show
        integrationGoalsStreamProvider,
        schedulerPreviewDecisionProvider,
        targetConstraintsStreamProvider;
import 'sequence/sequencer_run_event.dart' show SequencerRunEvent;
import 'sequence_provider.dart';
import 'sequence_stats_provider.dart'
    show sequenceRunsProvider, SequenceRunStats;
import 'session_provider.dart';
import 'plate_solver_provider.dart'
    show plateSolverDetectionProvider, plateSolverPreferenceProvider;
import 'settings_provider.dart' show appSettingsProvider;
import 'target_progress_provider.dart'
    show allTargetProgressProvider, targetProgressProvider;
import '../models/backend/backend_types.dart';
import 'capture_preview_loader_provider.dart';

part 'remote_sync/equipment_mirror.dart';
part 'remote_sync/imaging_mirror.dart';
part 'remote_sync/guiding_mirror.dart';
part 'remote_sync/sequencer_mirror.dart';
part 'remote_sync/host_mutation.dart';
part 'remote_sync/device_mapping.dart';
part 'remote_sync/reader_access.dart';
part 'remote_sync/session_hydration.dart';

/// Applies a backend or host-sync event to Riverpod state so UI refreshes
/// without navigation. Used by remote companions, the
/// desktop host when remote access is enabled, and API mutation publishers.
Future<void> applyRemoteSyncEvent(
  Object reader,
  SkotiqEvent event, {
  SkotiqBackend? networkBackend,
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
      _applySystemSyncEvent(reader, event, networkBackend: networkBackend);
      break;
    // A linked client takes the host's devices and guider from the runtime
    // channels; the host's own window follows the events.
    case EventCategory.equipment:
      if (networkBackend == null) _applyEquipmentEvent(reader, event);
      break;
    case EventCategory.guiding:
      if (networkBackend == null) _applyGuidingEvent(reader, event);
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
      // runs on a remote companion (no local executor), so the
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
      // Mirror the per-frame exposure countdown onto the camera card and the
      // exposure-progress readouts. These imaging events drive
      // [cameraStateProvider.setExposing] / [exposureProgressProvider] the way
      // ImagingService does for a capture it runs itself. A linked client
      // follows every exposure the host runs; the host follows the ones it
      // did not start (a client's snapshot, an API capture), which it used to
      // run with no "Exposing" countdown and no Abort.
      if (networkBackend != null) {
        _applyExposureMirror(reader, event.eventType, event.data);
      } else {
        _applyForeignExposureOnHost(reader, event.eventType, event.data);
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

void _applySystemSyncEvent(
  Object reader,
  SkotiqEvent event, {
  SkotiqBackend? networkBackend,
}) {
  if (event.eventType == hostStateChangedEventType) {
    _applyHostMutation(reader, event.data, onHost: networkBackend == null);
  } else if (event.eventType == hostRuntimeStateEventType &&
      networkBackend != null) {
    final update = HostRuntimeUpdate.fromJson(event.data);
    if (update != null) {
      applyHostRuntimeUpdate(reader, update, networkBackend: networkBackend);
    }
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
  SkotiqBackend backend, {
  HostFrameHint? hint,
}) {
  final fetchState = _remoteFrameFetchStates[reader] ??=
      _RemoteFrameFetchState();
  fetchState.hint = hint;
  unawaited(_publishRemoteCurrentFrame(reader, backend));
}
