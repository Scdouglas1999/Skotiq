import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting, listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_astro/format.dart';

import '../backend/remote_host.dart';
import '../backend/skotiq_backend.dart';
import '../utils/host_paths.dart';
import '../backend/network_backend.dart';
import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../models/flat_wizard/flat_capture_config.dart';
import '../models/imaging/imaging_models.dart' show FrameType;
import '../models/flat_wizard/flat_wizard_state.dart';
import '../models/flat_wizard/flat_wizard_settings.dart';
import '../services/flat_exposure_calculator.dart';
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
import 'profiles_provider.dart';
import '../models/equipment_profile_model.dart';
import '../database/daos/settings_dao.dart';
import '../models/backend/backend_types.dart';
import '../settings/setting.dart';
import '../settings/store_settings.dart';
import 'calibration_backlog_service_provider.dart';

part 'flat_wizard/flat_output_paths.dart';
part 'flat_wizard/flat_camera_config.dart';
part 'flat_wizard/flat_wizard_settings_ops.dart';
part 'flat_wizard/flat_wizard_run.dart';

final flatWizardProvider =
    StateNotifierProvider<FlatWizardNotifier, FlatWizardState>((ref) {
      return FlatWizardNotifier(ref);
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
    onHost: ref.watch(backendProvider).remoteHost != null,
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

  /// Test-only diagnostic sink. When set, the remote flat-history fault path
  /// invokes this with the caught error IN ADDITION to `developer.log`, so a
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
    ref.listen(filterWheelStateProvider, (previous, next) {
      if (previous?.deviceId != next.deviceId ||
          !listEquals(previous?.filterNames, next.filterNames)) {
        unawaited(loadFiltersFromWheel());
      }
    });
    ref.listen(activeEquipmentProfileProvider.select((p) => p?.id), (_, _) {
      unawaited(loadFiltersFromWheel());
    });
    ref.listen(cameraStateProvider.select((c) => c.deviceId), (_, _) {
      unawaited(loadFiltersFromWheel());
    });
  }

  bool _startPromptReserved = false;

  /// Whether capture startup or a capture run currently owns the wizard.
  bool get isBusy => _running || _startPromptReserved;

  void reset() {
    // Refuse to wipe state out from under an active run; cancel it instead.
    if (_running) {
      requestCancel();
      return;
    }
    _cancelToken = null;
    state = const FlatWizardState();
  }
}
