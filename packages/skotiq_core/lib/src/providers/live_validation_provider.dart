import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'equipment_provider.dart';
import 'profiles_provider.dart';
// sequence_provider.dart re-exports sequence/sequence_validation.dart, so the
// unified ValidationResult / ValidationIssue types are reachable through that
// single import. Don't add a direct import of sequence_validation.dart — the
// analyzer flags it as `unnecessary_import` and we want one canonical path.
import 'sequence_provider.dart';
import 'settings_provider.dart';

// Live validation provider
//
// Watches the current sequence + equipment state and runs the synchronous
// portion of the unified validation engine ([SequenceValidatorService.validateSync])
// on a 500ms debounce.
//
// The async disk-space check deliberately does NOT run here — it would fire on
// every keystroke. The pre-flight dialog runs the full async stack via
// [SequenceValidatorService.validate].
//
// The state exposed below ([LiveValidationState]) wraps a [ValidationResult].
// The wrapper carries no debounce flag (the pre-flight dialog tracks its own
// local one); it exists because the per-node helpers ([worstSeverityForNode]
// etc.) are part of the public live-validation API the sequence tree depends
// on.

/// Aggregated live validation state for tree-border colouring and the
/// header counts.
class LiveValidationState {
  final ValidationResult result;

  const LiveValidationState({required this.result});

  factory LiveValidationState.empty() =>
      LiveValidationState(result: ValidationResult.empty());

  List<ValidationIssue> get issues => result.issues;
  Map<String, List<ValidationIssue>> get issuesByNodeId =>
      result.issuesByNodeId;
  int get errorCount => result.errorCount;
  int get warningCount => result.warningCount;
  int get infoCount => result.infoCount;
  int get totalCount => result.totalCount;
  bool get hasErrors => result.hasErrors;
  bool get hasWarnings => result.hasWarnings;

  /// Worst severity (error > warning > info) for a specific node.
  ValidationSeverity? worstSeverityForNode(String nodeId) =>
      result.worstSeverityForNode(nodeId);
}

/// Runs live validation on the current sequence, debounced 500ms so a burst of
/// edits or device-state ticks revalidates once.
final liveValidationProvider =
    StateNotifierProvider<LiveValidationNotifier, LiveValidationState>((ref) {
      return LiveValidationNotifier(ref);
    });

class LiveValidationNotifier extends StateNotifier<LiveValidationState> {
  final Ref _ref;
  Timer? _debounceTimer;

  LiveValidationNotifier(this._ref) : super(LiveValidationState.empty()) {
    // Watch sequence changes
    _ref.listen(currentSequenceProvider, (_, __) {
      _scheduleValidation();
    });

    // Equipment state changes that affect validation, NARROWED to only the
    // slices the rule stack actually reads. The state snapshots also carry
    // high-frequency telemetry (camera temperature/cooler power, mount
    // RA/Dec, focuser position, guider RMS) that ticks many times a second;
    // listening to the whole snapshot re-ran the full rule stack on every
    // telemetry tick. Each `.select` below pins the validation-relevant
    // fields so churn that validation never reads no longer triggers a
    // re-run. Cooler-delta is the one rule that reads telemetry — we keep it
    // honest by listening to camera temperature rounded to a whole degree
    // (sub-degree wobble is noise; a real cooler change still refreshes).
    _ref.listen(
      filterWheelStateProvider.select(
        (s) => (s.connectionState, s.deviceId, s.filterNames),
      ),
      (_, __) => _scheduleValidation(),
    );
    _ref.listen(
      guiderStateProvider.select((s) => (s.connectionState, s.deviceId)),
      (_, __) => _scheduleValidation(),
    );
    _ref.listen(
      rotatorStateProvider.select((s) => (s.connectionState, s.deviceId)),
      (_, __) => _scheduleValidation(),
    );
    _ref.listen(
      mountStateProvider.select((s) => (s.connectionState, s.deviceId)),
      (_, __) => _scheduleValidation(),
    );
    _ref.listen(
      cameraStateProvider.select(
        (s) => (
          s.connectionState,
          s.deviceId,
          s.targetTemp,
          // Round to whole degrees so the cooler-delta rule refreshes on a
          // meaningful temperature change without re-validating on every
          // sub-degree telemetry tick.
          s.temperature?.round(),
        ),
      ),
      (_, __) => _scheduleValidation(),
    );
    _ref.listen(
      focuserStateProvider.select((s) => (s.connectionState, s.deviceId)),
      (_, __) => _scheduleValidation(),
    );

    // The active equipment PROFILE is a validation input too — several rules
    // (FilterInProfileRule, SmartExposureFilterNotInProfileRule) check node
    // filter names against `profile.filterNames`. Without this listen the
    // warning survives the operator fixing it: add the missing filter to the
    // profile, come back to the builder, and the badge still says the name is
    // not in the profile until something else happens to re-trigger a run.
    // The provider only recomputes when the profile store changes, so this is
    // not a churn source.
    _ref.listen(activeEquipmentProfileProvider, (_, __) {
      _scheduleValidation();
    });

    // Settings changes (image output path, etc.) influence validation too.
    _ref.listen(appSettingsProvider, (_, __) {
      _scheduleValidation();
    });

    // Run initial validation
    _scheduleValidation();
  }

  void _scheduleValidation() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) {
        _runValidation();
      }
    });
  }

  void _runValidation() {
    final sequence = _ref.read(currentSequenceProvider);
    if (sequence == null) {
      if (mounted) {
        state = LiveValidationState.empty();
      }
      return;
    }

    // We don't grab the provider here because the notifier is itself a
    // long-lived StateNotifier and the provider is autoDispose. Build the
    // service inline using the same default rule sets — the autoDispose
    // version exists so screen-scoped consumers can construct one without
    // dragging in the world.
    final service = SequenceValidatorService(
      ref: _ref,
      syncRules: defaultSequenceValidators,
      refAwareRules: defaultRefAwareSequenceValidators,
      asyncRules: const [],
    );
    final result = service.validateSync(sequence);

    if (mounted) {
      state = LiveValidationState(result: result);
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    super.dispose();
  }
}
