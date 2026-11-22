import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting, listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_astro/format.dart';

import 'linked_host.dart';
import '../backend/remote_host.dart';
import '../backend/skotiq_backend.dart';
import '../utils/host_paths.dart';
import '../errors/error_text.dart';
import 'host_role.dart';
import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../models/flat_wizard/flat_capture_config.dart';
import '../models/imaging/imaging_models.dart' show ExposureSettings, FrameType;
import '../models/flat_wizard/flat_wizard_state.dart';
import '../models/flat_wizard/flat_wizard_settings.dart';
import '../models/flat_wizard/flat_exposure_calculator.dart';
import '../services/calibration_backlog_service.dart';
import '../services/flat_exposure_follower.dart';
import '../services/frame_identity.dart';
import 'settings_provider.dart';
import '../services/flat_wizard_service.dart';
import '../services/sky_brightness_tracker.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'equipment_provider.dart';
import 'flat_wizard_output.dart';
import '../models/flat_wizard/flat_run_snapshot.dart';
import 'imaging_service_providers.dart';
import 'rig_activity.dart';
import 'profiles_provider.dart';
import '../models/equipment_profile_model.dart';
import '../database/daos/settings_dao.dart';
import '../models/backend/backend_types.dart';
import '../settings/setting.dart';
import '../settings/store_settings.dart';
import 'calibration_backlog_service_provider.dart';
import '../utils/logging_service.dart';

part 'flat_wizard/flat_output_paths.dart';
part 'flat_wizard/flat_camera_config.dart';
part 'flat_wizard/flat_wizard_settings_ops.dart';
part 'flat_wizard/flat_wizard_run.dart';
part 'flat_wizard/flat_wizard_remote.dart';

final flatWizardProvider =
    StateNotifierProvider<FlatWizardNotifier, FlatWizardState>((ref) {
      return FlatWizardNotifier(ref);
    });

/// Run metadata a linked client mirrors. Preview pixels travel separately.
final flatWizardSnapshotProvider = Provider<FlatRunSnapshot>((ref) {
  final state = ref.watch(flatWizardProvider);
  final output = ref.watch(flatRunOutputProvider);
  final image = state.lastImageData;
  return FlatRunSnapshot(
    state: state,
    busy: ref.read(flatWizardProvider.notifier).isBusy,
    previewKey: image is CapturedImageResult ? image.timestamp : null,
    output: output.filters,
  );
});

/// The folder flats are saved under: the one the operator chose, else
/// `Flats` in the capture folder (the host's on a linked client). Null only
/// when neither is set.
final flatWizardSaveFolderProvider = Provider<String?>((ref) {
  final chosen = ref.watch(
    flatWizardProvider.select((state) => state.globalSettings.savePath),
  );
  if (chosen != null && chosen.isNotEmpty) return chosen;
  final captureFolder =
      ref.watch(appSettingsProvider).valueOrNull?.imageOutputPath ?? '';
  return defaultFlatFolder(
    captureFolder,
    onHost: ref.watch(isRemoteModeProvider),
  );
});

/// A filter queued for capture, paired with its STABLE index into
/// `FlatWizardState.filterSettings`. Carrying the original index (rather than a
/// subset-local loop index) is what keeps per-filter status/count updates
/// aligned with the correct row in quick mode and with disabled leading
/// filters.
class _QueuedFilter {
  final int originalIndex;
  final FlatFilterSettings settings;

  const _QueuedFilter(this.originalIndex, this.settings);
}

class FlatWizardNotifier extends StateNotifier<FlatWizardState> {
  final Ref ref;

  /// Cancellation token for the in-flight capture run. Non-null only while a
  /// run holds the busy latch. [requestCancel] cancels it; the run polls and
  /// races it so a cancel that lands mid-exposure aborts the hardware.
  FlatCancelToken? _cancelToken;

  /// Busy latch. Held for the whole duration of [runCapture] so a second
  /// start cannot race in (double-start) and the filter list cannot be
  /// reordered/toggled out from under the stable capture indices.
  bool _running = false;

  /// The imaging host's run, mirrored onto this client. Set from a snapshot;
  /// the capture itself is not in this process.
  bool _remoteBusy = false;
  Object? _pendingHostStart;
  int _hostSnapshotRevision = 0;

  /// Preview key last applied from the host. A decode for an older key, or
  /// one that finishes after dispose, is dropped.
  String? _remotePreviewKey;
  int _previewGeneration = 0;

  /// Test-only diagnostic sink. When set, the remote flat-history fault path
  /// invokes this with the caught error IN ADDITION to the app log, so a
  /// test can prove a transport fault was distinguished from an empty host
  /// history (it fires on the fault path and stays silent on empty history).
  /// Null in production — behaviour is unchanged.
  @visibleForTesting
  void Function(Object error)? debugRemoteFaultSink;

  /// Bumped on every user settings edit. The async hydrate captures this before
  /// its DB read and re-checks it afterward; a hydrate that resolves AFTER the
  /// user (or a run) has already touched the settings is discarded so it cannot
  /// clobber a live edit — mirrors PolarAlignmentConfigNotifier's load guard.
  int _settingsRevision = 0;
  int _filterRevision = 0;
  String? _loadedFilterKey;
  Future<void>? _filterLoad;
  bool _filterReloadRequested = false;
  Future<void> _filterSettingsWrite = Future.value();

  FlatWizardNotifier(this.ref) : super(const FlatWizardState()) {
    unawaited(_hydrateGlobalSettings());
    ref.listenAcrossHosts((host) => host?.flatWizard, (_) {
      _pendingHostStart = null;
      _remoteBusy = false;
      _remotePreviewKey = null;
      _previewGeneration++;
      if (_running) return;
      _cancelToken = null;
      _settingsRevision++;
      _filterRevision++;
      _loadedFilterKey = null;
      state = FlatWizardState(
        mode: state.mode,
        twilightMode: state.twilightMode,
        showAduGraph: state.showAduGraph,
        showExposureTimeline: state.showExposureTimeline,
        showSkyBrightness: state.showSkyBrightness,
        showFilterCards: state.showFilterCards,
        showHistogramOverlay: state.showHistogramOverlay,
      );
      ref.read(flatRunOutputProvider.notifier).state = const FlatRunOutput();
      unawaited(_hydrateGlobalSettings(restoreSavePath: false));
      unawaited(loadFilters());
    });
    ref.listen(effectiveFiltersProvider, (previous, next) {
      if (!listEquals(previous, next)) unawaited(loadFilters());
    });
    ref.listen(filterWheelStateProvider.select((w) => w.deviceId), (_, _) {
      unawaited(loadFilters());
    });
    ref.listen(activeEquipmentProfileProvider.select((p) => p?.id), (_, _) {
      unawaited(loadFilters());
    });
    ref.listen(cameraStateProvider.select((c) => c.deviceId), (_, _) {
      unawaited(loadFilters());
    });
  }

  bool _startPromptReserved = false;

  /// The camera is running on this process, so changing backends would orphan it.
  bool get localRunActive => _running;

  bool get _captureActive =>
      _running || _remoteBusy || _pendingHostStart != null;

  /// Whether capture startup, a local run, or a mirrored host run owns the
  /// wizard.
  bool get isBusy => _captureActive || _startPromptReserved;

  /// The host checks this synchronously at the point it admits a draft.
  String? get startBlockReason {
    if (isBusy) return 'A flat capture is already in progress';
    final held = rigHeldBy(ref.read, starting: RigActivity.flats);
    if (held != null) return held.busy;
    if (ref.read(cameraStateProvider).isExposing) {
      return 'Camera is busy with another exposure';
    }
    return null;
  }

  void reset() {
    // Refuse to wipe state out from under an active run; cancel it instead.
    if (_captureActive) {
      requestCancel();
      return;
    }
    _cancelToken = null;
    state = const FlatWizardState();
  }
}
