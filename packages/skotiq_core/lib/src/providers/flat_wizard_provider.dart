import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import '../backend/network_backend.dart';
import '../models/backend/fits_header.dart' show FitsWriteHeader;
import '../models/backend/image_result.dart' show CapturedImageResult;
import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../models/flat_wizard/flat_capture_config.dart';
import '../models/flat_wizard/flat_wizard_state.dart';
import '../models/flat_wizard/flat_wizard_settings.dart';
import '../services/flat_exposure_calculator.dart';
import '../services/flat_wizard_service.dart';
import '../services/sky_brightness_tracker.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'equipment_provider.dart';
import 'profiles_provider.dart';

part 'flat_wizard/flat_output_paths.dart';
part 'flat_wizard/flat_camera_config.dart';
part 'flat_wizard/flat_wizard_settings_ops.dart';
part 'flat_wizard/flat_wizard_run.dart';

/// Provider for flat wizard state
final flatWizardProvider =
    StateNotifierProvider<FlatWizardNotifier, FlatWizardState>((ref) {
      return FlatWizardNotifier(ref);
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

  /// Settings key the persisted global-settings JSON blob lives under (the six
  /// user-facing fields — save path, targets, frame count, subfolder toggles).
  static const String _globalSettingsKey = 'flat_wizard_global_settings';

  /// Bumped on every user settings edit. The async hydrate captures this before
  /// its DB read and re-checks it afterward; a hydrate that resolves AFTER the
  /// user (or a run) has already touched the settings is discarded so it cannot
  /// clobber a live edit — mirrors PolarAlignmentConfigNotifier's load guard.
  int _settingsRevision = 0;

  FlatWizardNotifier(this.ref) : super(const FlatWizardState()) {
    unawaited(_hydrateGlobalSettings());
  }

  // Capture control

  bool _startPromptReserved = false;

  /// Whether capture startup or a capture run currently owns the wizard.
  bool get isBusy => _running || _startPromptReserved;

  // Reset

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
