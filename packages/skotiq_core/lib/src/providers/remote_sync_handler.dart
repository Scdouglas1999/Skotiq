import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import '../backend/skotiq_backend.dart';
import '../backend/bridge_event_mapper.dart' show tryBridgeEventFromCoreEvent;
import '../backend/bridge_events.dart' as bridge;
import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../models/backend/host_mutation_event.dart';
import '../models/backend/host_runtime_update.dart';
import '../models/imaging/imaging_models.dart'
    show CapturePreviewSource, ExposureSettings, FramePurpose;
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
import 'device_service_providers.dart';

part 'remote_sync/equipment_mirror.dart';
part 'remote_sync/imaging_mirror.dart';
part 'remote_sync/guiding_mirror.dart';
part 'remote_sync/sequencer_mirror.dart';
part 'remote_sync/host_mutation.dart';
part 'remote_sync/device_mapping.dart';
part 'remote_sync/reader_access.dart';
part 'remote_sync/session_hydration.dart';

/// The host's own window following what happened through its server: a
/// linked client connected a device, started a capture or changed stored
/// data, or the native side announced it while no service was listening.
void applyHostLocalSyncEvent(ProviderContainer container, SkotiqEvent event) {
  switch (event.category) {
    case EventCategory.system:
      if (event.eventType != hostStateChangedEventType) return;
      final change = HostDataChange.of(event.data);
      if (change == null) return;
      switch (change.entityType) {
        case HostMutationEntity.equipment:
          _applyEquipmentMutationFromHost(container, change.action, event.data);
        case HostMutationEntity.guider:
          _applyGuiderMutationFromHost(container, change.action, event.data);
        default:
          _rereadChangedHostData(container, change, event.data);
      }
    case EventCategory.equipment:
      _applyEquipmentEvent(container, event);
    case EventCategory.guiding:
      _applyGuidingEvent(container, event);
    case EventCategory.sequencer:
      // The run's own events are folded by the executor attached to it.
      _applySequenceLibraryNotice(container, event);
    case EventCategory.imaging:
      _rereadImagesAfter(container, event);
      // A capture the host runs itself drives its own countdown; this shows
      // one it did not start (a client's snapshot, an API capture).
      _applyForeignExposureOnHost(container, event);
    case EventCategory.safety:
    case EventCategory.polarAlignment:
    case EventCategory.job:
    case EventCategory.session:
    case EventCategory.catalog:
      break;
  }
}

/// A linked client following one event of its host, [backend].
///
/// The host's devices, guider and the results only its process computes
/// arrive as runtime channel values ([applyHostRuntimeUpdate]); its run is
/// folded from its sequencer events; a change to its stored data re-reads
/// that data.
void applyHostEventOnClient(
  ProviderContainer container,
  SkotiqBackend backend,
  SkotiqEvent event,
) {
  if (!identical(container.read(backendProvider), backend)) return;
  switch (event.category) {
    case EventCategory.system:
      if (event.eventType == hostStateChangedEventType) {
        final change = HostDataChange.of(event.data);
        if (change == null) return;
        if (change.entityType == HostMutationEntity.sequencer) {
          _mirrorHostRunControl(container, change.action, event.data);
        } else {
          _rereadChangedHostData(container, change, event.data);
        }
      } else if (event.eventType == hostRuntimeStateEventType) {
        final update = HostRuntimeUpdate.fromJson(event.data);
        if (update != null) {
          applyHostRuntimeUpdate(container, update, networkBackend: backend);
        }
      }
    case EventCategory.sequencer:
      if (_applySequenceLibraryNotice(container, event)) return;
      _mirrorHostRunEvent(container, backend, event);
    case EventCategory.imaging:
      _rereadImagesAfter(container, event);
      // The capture publisher runs only on the host, so the host's frame is
      // fetched here when it says one is ready; a saved or captured frame
      // counts too, in case the ready event was missed.
      if (event.eventType == 'ImageReady' ||
          event.eventType == 'ImageSaved' ||
          event.eventType == 'ImageCaptured') {
        unawaited(_publishRemoteCurrentFrame(container, backend));
      }
      _applyExposureMirror(container, event);
    case EventCategory.equipment:
    case EventCategory.guiding:
    case EventCategory.safety:
    case EventCategory.polarAlignment:
    case EventCategory.job:
    case EventCategory.session:
    case EventCategory.catalog:
      break;
  }
}

void _rereadImagesAfter(ProviderContainer container, SkotiqEvent event) {
  if (event.eventType == 'ImageCaptured' || event.eventType == 'ImageSaved') {
    _invalidateHostCapturedImages(container);
  }
}

/// Fetch the host's newest frame into this client's current image, as a frame
/// event from the host would. Coalesces with a fetch already running.
///
/// [hint] describes the frame the host announced; when the fetched frame has
/// its dimensions, it takes the host's saved path, target and capture settings,
/// which the last-frame endpoint does not carry.
void requestHostCurrentFrame(
  ProviderContainer container,
  SkotiqBackend backend, {
  HostFrameHint? hint,
}) {
  final fetchState = container.read(_remoteFrameFetchStateProvider);
  fetchState.hint = hint;
  unawaited(_publishRemoteCurrentFrame(container, backend));
}
