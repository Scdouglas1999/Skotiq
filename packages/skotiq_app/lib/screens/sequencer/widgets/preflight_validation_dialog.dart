import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/gated_action.dart';
import 'mount_unpark_dialog.dart';
import 'sequence_diff_dialog.dart';
import 'session_handoff_dialog.dart';
import 'visual_timeline.dart';
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

/// Pre-flight validation dialog
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
      );
      return (simulation, null);
    } catch (e) {
      return (null, 'Simulation failed: $e');
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

  /// Handle starting the sequence, checking for mount parking first.
  ///
  /// Before kicking off the mount-unpark flow we surface the
  /// multi-night carry-over dialog when (a) at least one target has
  /// recent unfinished integration and (b) the
  /// `sessionHandoffAutoPrompt` setting is on. The decision is recorded
  /// in [sessionHandoffDecisionProvider]; the executor reads that value
  /// at sequence start so the IntegrationBudget tracker can either
  /// reuse or ignore the prior-session frames.
  Future<void> _handleStartSequence() async {
    // Check if a mount is connected and parked
    final mountState = ref.read(mountStateProvider);
    final isMountConnected =
        mountState.connectionState == DeviceConnectionState.connected;
    final isMountParked = mountState.isParked;
    // Read synchronously, before any await: this is the tree the operator
    // pressed Start on, and it decides whether the run needs the mount at all.
    final sequence = ref.read(currentSequenceProvider);

    // Capture a navigator that outlives this dialog so the follow-on handoff /
    // unpark dialogs can be shown AFTER we pop the preflight dialog without
    // relying on this State's (soon-to-be-defunct) context.
    final navigator = Navigator.of(context);

    // Do the async prep (multi-night carry-over lookup) while the dialog is
    // still on screen, showing a "Preparing…" body — rather than popping
    // first and awaiting invisibly. This gives the operator a visible state
    // between pressing Start and the next dialog appearing.
    setState(() => _preparing = true);
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
      if (_preparing) {
        setState(() => _preparing = false);
      }
    } else {
      setState(() => _preparing = false);
    }

    // Prep finished — close the preflight dialog just before showing the next
    // dialog so the user never sees a dead-but-open preflight while awaiting.
    if (mounted) {
      Navigator.of(context).pop();
    }

    // Surface the carry-over handoff dialog when there is something to carry.
    if (carry.isNotEmpty) {
      if (!navigator.mounted) return;
      final sequenceId = ref.read(currentSequenceProvider)?.databaseId;
      final decisions = await SessionHandoffDialog.show(
        context: navigator.context,
        sequenceId: sequenceId,
        carryOvers: carry,
      );
      // null = user cancelled the handoff dialog entirely — abort the
      // sequence start in case they intended to back out.
      if (decisions == null) return;
    }

    // A parked mount only has to come off its park if something in this run
    // actually needs the sky. A calibration block does not: the executor takes
    // darks, biases and flats without ever issuing a slew, so the dialog's
    // promise that "the sequence will automatically unpark the mount and
    // continue" described an unpark the run had no use for — and then
    // performed it, leaving the mount off its park for a run of three darks.
    final needsSky = sequence == null || sequenceNeedsMountOffPark(sequence);

    // If mount is connected and parked, show the unpark dialog. An armed
    // start unparks when it fires, not hours early.
    if (isMountConnected && isMountParked && needsSky && !widget.armOnly) {
      if (!navigator.mounted) return;
      final result = await showMountUnparkDialog(navigator.context);

      // Only start the sequence if the user chose to unpark
      if (result == MountUnparkResult.unparkAndContinue) {
        _authorizeStartWithoutHistory(startWithoutHistory);
        widget.onStartSequence?.call();
      }
      // If cancelled, do nothing (sequence won't start)
    } else {
      // Mount not parked, not connected, or parked with nothing in the run
      // that needs it moved — start, and leave the park exactly as it is.
      _authorizeStartWithoutHistory(startWithoutHistory);
      widget.onStartSequence?.call();
    }
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
              error.toString(),
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

  String _formatClock(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
}
