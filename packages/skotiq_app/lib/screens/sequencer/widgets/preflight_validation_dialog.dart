import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/gated_action.dart';
import '../../../services/mount_command_service.dart';
import 'sequence_diff_dialog.dart';
import 'session_handoff_dialog.dart';
import 'visual_timeline.dart';
import '../../../utils/darkroom_navigation.dart';
part 'preflight_validation_dialog/simulation_widgets.dart';
part 'preflight_validation_dialog/action_widgets.dart';
part 'preflight_validation_dialog/issue_section.dart';

part 'preflight_validation_dialog/section_builders.dart';

// PRE-FLIGHT VALIDATION DIALOG
//
// UI shell for the canonical sequence validator. The validation engine
// lives in `skotiq_core/.../sequence/sequence_validation.dart` — this
// file only renders the result. It consumes that engine's ValidationIssue /
// ValidationSeverity / ValidationResult types directly, so there is one source
// of truth for sequence validation across the app.

class PreFlightValidationDialog extends ConsumerStatefulWidget {
  final VoidCallback? onStartSequence;

  /// The primary button's label; null for "Start sequence".
  final String? startLabel;

  /// Arming a start for later (Tonight's Start at dark): the run is checked
  /// as if it started at [simulationStart], and a parked mount is not
  /// unparked now. The armed start unparks it when it fires.
  final bool armOnly;

  /// When the run will start; null for now.
  final DateTime? simulationStart;

  const PreFlightValidationDialog({
    super.key,
    this.onStartSequence,
    this.startLabel,
    this.armOnly = false,
    this.simulationStart,
  });

  @override
  ConsumerState<PreFlightValidationDialog> createState() =>
      _PreFlightValidationDialogState();
}

class _PreFlightValidationDialogState
    extends ConsumerState<PreFlightValidationDialog> {
  ValidationResult? _result;
  Object? _validationError;
  PreSessionSimulationResult? _simulation;
  String? _simulationUnavailableReason;
  bool _isValidating = true;

  /// True while the async start prep (multi-night carry-over lookup) is in
  /// flight. The dialog stays open showing a "Preparing…" body instead of
  /// popping immediately and then awaiting off-screen — so the operator gets
  /// a visible state between pressing Start and the next dialog appearing.
  bool _preparing = false;

  /// The start is taking the mount off its park.
  bool _unparking = false;

  /// Why the last Start stopped short (a failed unpark); shown above the
  /// results until the next press.
  String? _startError;

  /// Diff vs the most recent COMPLETED run of this sequence. `null`
  /// either means we haven't computed it yet, or there
  /// is no previous run to compare against (fresh sequence, or first
  /// successful run still pending). When non-null AND non-empty we
  /// surface a small info-banner near the top of the dialog with a
  /// "View N changes" link.
  SequenceDiffResult? _previousRunDiff;

  @override
  void initState() {
    super.initState();
    _runValidation();
    _computePreviousRunDiff();
  }

  Future<void> _runValidation() async {
    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) {
      if (mounted) {
        setState(() {
          _result = null;
          _validationError = null;
          _isValidating = false;
        });
      }
      return;
    }

    try {
      final validator = ref.read(sequenceValidatorProvider);
      final result = await validator.validate(sequence);
      final (simulation, simulationUnavailableReason) =
          await _simulateCurrentSequence(sequence);

      if (mounted) {
        setState(() {
          _result = result;
          _validationError = null;
          _simulation = simulation;
          _simulationUnavailableReason = simulationUnavailableReason;
          _isValidating = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _result = null;
        _validationError = error;
        _simulation = null;
        _simulationUnavailableReason = null;
        _isValidating = false;
      });
    }
  }

  /// Rename the plan's filters to the names the wheel (or the profile) uses
  /// for the same filters, then check again.
  void _matchFilterNames(Map<String, String> renames) {
    ref.read(currentSequenceProvider.notifier).renameFilterNames(renames);
    setState(() => _isValidating = true);
    _runValidation();
  }

  void _retryValidation() {
    ref.invalidate(appSettingsProvider);
    setState(() {
      _validationError = null;
      _isValidating = true;
    });
    _runValidation();
  }

  Future<(PreSessionSimulationResult?, String?)> _simulateCurrentSequence(
    Sequence sequence,
  ) async {
    final settings = await ref.read(appSettingsProvider.future);
    if (!settings.hasObserverLocation) {
      return (
        null,
        'Set observer latitude and longitude to simulate target visibility.',
      );
    }

    try {
      final twilight = ref.read(preSessionTwilightTimesProvider);
      // Same overhead model the Builder's estimate chip and the timeline use.
      // Left on the estimator's own defaults, this panel printed a different
      // duration for the sequence the Builder had just estimated one row away.
      final simulation = PreSessionSimulator(
        estimator: SequenceTimeEstimator(
          overhead: ref.read(sequencerOverheadConfigProvider),
        ),
      ).simulate(
        sequence,
        start: widget.simulationStart ?? DateTime.now(),
        latitude: settings.latitude,
        longitude: settings.longitude,
        minAltitude: settings.effectiveHorizonDeg,
        darkWindowStart: twilight?.astronomicalDusk,
        darkWindowEnd: twilight?.astronomicalDawn,
        framesDone: ref.read(restoredCheckpointProvider) == null
            ? const {}
            : ref.read(framesDoneBeforeRunProvider),
      );
      return (simulation, null);
    } catch (e) {
      return (null, 'Simulation failed: ${userFacingError(e)}');
    }
  }

  /// Resolve the most recent COMPLETED run of the current sequence and
  /// compute a structural diff against the in-editor copy. The diff is
  /// informational only — pre-flight does NOT block on it; the link
  /// just lets the operator review what's changed since the last
  /// known-good run.
  ///
  /// We swallow errors quietly: a missing repository, missing DAO, or
  /// stale node-id mapping should not block the user from starting the
  /// sequence. The link simply won't appear in those cases.
  Future<void> _computePreviousRunDiff() async {
    try {
      final sequence = ref.read(currentSequenceProvider);
      if (sequence == null) return;
      final sequenceDbId = sequence.databaseId;
      if (sequenceDbId == null) {
        // Sequence has never been persisted — no run history to diff.
        return;
      }
      final runs = await ref.read(
        sequenceRunsForSequenceProvider(sequenceDbId).future,
      );
      // Filter to "completed" runs only; failed / cancelled / running
      // runs are not the operator's reference point for "last known
      // good".
      SequenceRun? lastCompleted;
      for (final r in runs) {
        if (r.status == 'completed') {
          lastCompleted = r;
          break;
        }
      }
      if (lastCompleted == null) return;

      // We don't yet snapshot the sequence definition inside each run
      // row (see [SequenceDiffDialog.showForRun] for context), so the
      // diff against the persisted current sequence is the best we can
      // do. The diff service is structural by node id; if the user has
      // genuinely changed nothing, this returns an empty result and
      // we skip the banner.
      final repo = ref.read(sequenceRepositoryProvider);
      final persisted = await repo.loadSequence(sequenceDbId);
      if (persisted == null) return;
      final diffService = ref.read(sequenceDiffServiceProvider);
      final result = diffService.diff(
        previous: persisted,
        current: sequence,
      );
      if (result.isEmpty) return;
      if (!mounted) return;
      setState(() => _previousRunDiff = result);
    } catch (_) {
      // Quietly skip — pre-flight is not the place to bubble up
      // diff-resolution errors. The link just won't appear.
    }
  }

  /// Whether Start takes the mount off its park first: it is connected and
  /// parked, and something in this run needs the sky. A calibration block
  /// does not (the executor takes darks, biases and flats without a slew),
  /// and an armed start unparks when it fires, not hours early. The dialog
  /// lists it, so pressing Start is the consent and no second gate follows.
  bool _startUnparks(MountState mount, Sequence? sequence) =>
      !widget.armOnly &&
      mount.connectionState == DeviceConnectionState.connected &&
      mount.isParked &&
      (sequence == null || sequenceNeedsMountOffPark(sequence));

  /// Start: the multi-night carry-over decision, then the unpark the dialog
  /// listed, then the run. The dialog stays open, saying what it is doing,
  /// until the run is asked to start; a failed unpark keeps it open with the
  /// reason and starts nothing.
  ///
  /// The carry-over decision is recorded in [sessionHandoffDecisionProvider];
  /// the executor reads it at sequence start so the IntegrationBudget tracker
  /// can either reuse or ignore the prior-session frames.
  Future<void> _handleStartSequence() async {
    // Read before any await: this is the tree and the mount the operator
    // pressed Start on.
    final unpark = _startUnparks(
      ref.read(mountStateProvider),
      ref.read(currentSequenceProvider),
    );

    setState(() {
      _preparing = true;
      _startError = null;
    });
    late final bool autoPrompt;
    try {
      autoPrompt = await ref.read(sessionHandoffAutoPromptProvider.future);
    } catch (error) {
      if (!mounted) return;
      setState(() => _preparing = false);
      final retry = await _confirmRetrySettings(error);
      if (!retry || !mounted) return;
      ref.invalidate(appSettingsProvider);
      ref.invalidate(sessionHandoffAutoPromptProvider);
      return _handleStartSequence();
    }
    if (!mounted) return;
    List<SessionCarryOver> carry = const <SessionCarryOver>[];
    var startWithoutHistory = false;
    if (autoPrompt) {
      try {
        carry = await ref.read(sessionCarryOverProvider.future);
      } catch (error) {
        if (!mounted) return;
        setState(() => _preparing = false);
        startWithoutHistory = await _confirmStartWithoutHistory(error);
        if (!startWithoutHistory || !mounted) return;
      }
      if (!mounted) return;
    }

    if (carry.isNotEmpty) {
      final sequenceId = ref.read(currentSequenceProvider)?.databaseId;
      final decisions = await SessionHandoffDialog.show(
        context: context,
        sequenceId: sequenceId,
        carryOvers: carry,
      );
      if (!mounted) return;
      // null = the operator backed out of the handoff: start nothing.
      if (decisions == null) {
        setState(() => _preparing = false);
        return;
      }
    }

    if (unpark && ref.read(mountStateProvider).isParked) {
      setState(() {
        _preparing = true;
        _unparking = true;
      });
      final result = await ref.read(mountCommandServiceProvider).unpark();
      if (!mounted) return;
      if (!result.isSuccess) {
        setState(() {
          _preparing = false;
          _unparking = false;
          _startError = result.message ??
              'The mount did not unpark, so the run was not started.';
        });
        return;
      }
    }

    Navigator.of(context).pop();
    _authorizeStartWithoutHistory(startWithoutHistory);
    widget.onStartSequence?.call();
  }

  void _authorizeStartWithoutHistory(bool authorized) {
    if (!authorized || widget.onStartSequence == null) return;
    ref.read(sessionHandoffIgnoreUnavailableOnceProvider.notifier).state = true;
  }

  Future<bool> _confirmStartWithoutHistory(Object error) async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => SkotiqDialog(
            title: 'Prior-session history unavailable',
            icon: SkotiqIcons.database,
            width: SkotiqDialog.widthConfirm,
            onClose: () => Navigator.of(dialogContext).pop(false),
            actions: [
              SkotiqButton(
                label: 'Cancel',
                variant: ButtonVariant.ghost,
                onPressed: () => Navigator.of(dialogContext).pop(false),
              ),
              SkotiqButton(
                label: 'Start without prior progress',
                variant: ButtonVariant.start,
                onPressed: () => Navigator.of(dialogContext).pop(true),
              ),
            ],
            child: _confirmBody(
              dialogContext,
              'Skotiq could not read the accepted frames from prior '
              'sessions. Starting without them can reset a multi-night '
              'integration budget to zero and recapture work you already '
              'completed. No hardware has started.',
              error,
            ),
          ),
        ) ??
        false;
  }

  Future<bool> _confirmRetrySettings(Object error) async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => SkotiqDialog(
            title: 'Sequence settings unavailable',
            icon: SkotiqIcons.settings,
            width: SkotiqDialog.widthConfirm,
            onClose: () => Navigator.of(dialogContext).pop(false),
            actions: [
              SkotiqButton(
                label: 'Cancel',
                variant: ButtonVariant.ghost,
                onPressed: () => Navigator.of(dialogContext).pop(false),
              ),
              SkotiqButton(
                label: 'Retry',
                icon: SkotiqIcons.refresh,
                onPressed: () => Navigator.of(dialogContext).pop(true),
              ),
            ],
            child: _confirmBody(
              dialogContext,
              'Skotiq could not load the settings that control '
              'multi-night carry-over. The sequence has not started.',
              error,
            ),
          ),
        ) ??
        false;
  }

  /// One sentence of explanation over the raw error in a `well`.
  ///
  /// The error text stays selectable — it is the string an operator pastes
  /// into a bug report — but through a [SelectionArea] rather than a
  /// `SelectableText`, so the sentence above it copies with it.
  Widget _confirmBody(
    BuildContext dialogContext,
    String explanation,
    Object error,
  ) {
    final colors = SkotiqColors.of(dialogContext);
    return SelectionArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            explanation,
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
            decoration: SkotiqDecorations.well(colors),
            child: Text(
              userFacingError(error),
              style: SkotiqTypography.monoXs.copyWith(color: colors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  /// The dialog's design height. Fixed so the verdict banner and the footer
  /// keep their place while the body scrolls, rather than the whole dialog
  /// resizing under the operator as sections expand and collapse.
  static const double _designHeight = 600;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return SkotiqDialog(
      title: 'Pre-flight check',
      width: SkotiqDialog.widthForm,
      height: _designHeight,
      // Blocks the close button, the barrier and system-back for exactly as
      // long as the carry-over lookup is in flight.
      closeEnabled: !_preparing,
      // Hidden while preparing so the operator cannot double-trigger the start
      // while that lookup is still running.
      actions: _preparing ? null : _buildActions(colors),
      child: _preparing
          ? _buildPreparingState(colors)
          : _isValidating
              ? _buildLoadingState(colors)
              : _result == null
                  ? _buildErrorState(colors)
                  : _buildResults(colors),
    );
  }
}
