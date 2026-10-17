// Guided action rail for the survey-backed Framing Wizard (component C7).
//
// `FramingActionRail` is the in-place "wizard" UX: a vertical
// `NightshadeCard` of numbered, ordered steps that walks the user from a
// resolved target all the way to a one-click slew/center/rotate. It is a
// dedicated widget in its own file so the framing sidebar (owned elsewhere)
// can mount it without us reaching into shared sidebar code.
//
// Each step carries a `StatusPill` that reads `success` once that step's
// precondition is satisfied, so the rail doubles as a live readiness
// checklist:
//   1. Target  — resolved name / RA / Dec (read `framingProvider`), or an
//                 `EmptyState.compact` prompting the user to pick a target.
//   2. Frame   — survey-source `NightshadeDropdown` + the (reused, read-only)
//                 `FramingPreviewFovSlider` so the user can dial the cutout
//                 they're about to solve and slew to.
//   3. Solve   — runs `plateSolveServiceProvider.solveWithFallback` on the
//                 latest real camera frame. A `SolverNotAvailableError`
//                 surfaces the existing `PlateSolverRequiredBanner`; a
//                 successful solve reports the RA/Dec delta versus the target
//                 in a `NightshadeBanner`.
//   4. GoTo    — embeds the existing `SlewDropdownButton` (the complete
//                 slew + center + rotate flow), passing the framing rotation as
//                 the target angle so "Slew, Center & Rotate" lights up when a
//                 rotator is connected.
//
// Errors are surfaced, never swallowed — a solve failure shows
// the solver's own error message; an IO failure writing the frame to disk shows
// the failure rather than silently degrading.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nightshade_core/nightshade_core.dart';
import 'package:nightshade_ui/nightshade_ui.dart';

import 'package:nightshade_app/utils/snackbar_helper.dart';
import 'package:nightshade_app/widgets/plate_solver_required_banner.dart';
import 'package:nightshade_app/widgets/slew_dropdown_button.dart';
import '../../../widgets/tutorial_keys/framing_keys.dart';
import '../framing_altaz.dart';
import 'framing_controls.dart' show FramingPreviewFovSlider;

/// Identifies the GoTo step's readiness pill (several steps read 'Ready').
const framingGotoStatusKey = Key('framing.goto.status');

/// Outcome of a "Solve current frame" attempt, rendered inline beneath the
/// solve step. Exactly one of [result] / [error] / [solverMissing] is set.
@immutable
class _SolveOutcome {
  /// A solver-reported result (which may itself be `success == false`).
  final PlateSolveResult? result;

  /// The target the frame was solved against, used to compute the offset.
  final FramingTarget? against;

  /// A non-solver error string (IO failure, unexpected exception).
  final String? error;

  /// `true` when no plate solver is reachable; drives the inline banner.
  final bool solverMissing;

  const _SolveOutcome._({
    this.result,
    this.against,
    this.error,
    this.solverMissing = false,
  });

  factory _SolveOutcome.solved(
          PlateSolveResult result, FramingTarget against) =>
      _SolveOutcome._(result: result, against: against);

  factory _SolveOutcome.failed(String error) => _SolveOutcome._(error: error);

  const _SolveOutcome.noSolver() : this._(solverMissing: true);
}

/// The guided, numbered action rail for the framing wizard.
///
/// Stateful so it can own the transient solve state (in-flight flag + last
/// outcome) without pushing it into the shared framing provider — the outcome
/// is purely presentational and scoped to this rail's lifetime.
class FramingActionRail extends ConsumerStatefulWidget {
  const FramingActionRail({super.key});

  @override
  ConsumerState<FramingActionRail> createState() => _FramingActionRailState();
}

class _FramingActionRailState extends ConsumerState<FramingActionRail> {
  bool _isSolving = false;
  _SolveOutcome? _lastSolve;
  int _solveRevision = 0;
  ProviderSubscription<NightshadeBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<NightshadeBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        _solveRevision++;
        if (mounted && (_isSolving || _lastSolve != null)) {
          setState(() {
            _isSolving = false;
            _lastSolve = null;
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = NightshadeColors.of(context);
    final framingState = ref.watch(framingProvider);
    final equipmentAsync = ref.watch(framingFOVProvider);
    final solverDetection = ref.watch(plateSolverDetectionProvider);
    final solverPreference = ref.watch(plateSolverPreferenceProvider);

    final target = framingState.target;
    // The aim is where the telescope will actually point — the dragged
    // reticle's coordinates, or the view-center target when the box has not
    // been dragged. Pointing consumers below (slew, solve hint, the horizon
    // advisory) read this; the picked `target` itself only feeds display of
    // the resolved object (step 1) and the slew button's targetName.
    final aimTarget = framingState.effectiveAimTarget;
    final hasTarget = target != null;
    final hasSurveyImage = framingState.surveyImageBytes != null;
    final latestCameraFrame = ref.watch(currentImageProvider);
    final hasCameraFrame = latestCameraFrame?.filePath != null;
    final detection = solverDetection.valueOrNull;
    final preference = solverPreference.valueOrNull;
    final hasSolver = detection != null &&
        preference != null &&
        detection.supports(preference.choice);

    final equipment = equipmentAsync.valueOrNull;
    final hasEquipment = equipment?.isReady ?? false;

    // Step 4 must be badged from the SAME predicate that enables its button.
    // [SlewDropdownButton] gates itself on the mount being connected, but this
    // step's badge was driven by `hasTarget` alone — so with the mount
    // disconnected it showed a green "Ready" over a button that swallowed every
    // click in silence.
    final mountState = ref.watch(mountStateProvider);
    final isMountConnected =
        mountState.connectionState == DeviceConnectionState.connected;
    // A PARKED mount cannot GoTo — every driver refuses, most of them without
    // an error the UI ever sees, so the rail must not show "Ready" and a filled
    // primary button over one. `isParked` defaults to true on an unknown mount,
    // so it is only consulted once the mount is actually connected and
    // reporting status.
    final isMountParked = isMountConnected && mountState.isParked;
    final canSlew = hasTarget && isMountConnected && !isMountParked;

    // Altitude is advisory, not a gate: a target below the horizon now will
    // rise, and the operator may legitimately want the mount pre-pointed. But
    // "Ready" over a target 5.7 deg under the ground would be false, so the
    // badge says which it is. Null means no configured site
    // (the app cannot know the altitude), in which case we claim nothing.
    // Measured at the AIM — the slew destination — not the view center.
    final targetAltitudeDeg = _targetAltitudeDeg(aimTarget);
    final isBelowHorizon = targetAltitudeDeg != null && targetAltitudeDeg < 0;

    return NightshadePanel(
        padding: NightshadeTokens.cardPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Guided framing',
              subtitle: 'Resolve, frame, solve, and slew in order',
            ),
            const SizedBox(height: NightshadeTokens.spaceSm),

            // Step 1: target
            _StepRow(
              number: 1,
              title: 'Target',
              status: hasTarget
                  ? StatusPillStatus.success
                  : StatusPillStatus.inactive,
              statusValue: hasTarget ? 'Resolved' : 'None',
              colors: colors,
              child: hasTarget
                  ? _TargetSummary(colors: colors, target: aimTarget!)
                  : const EmptyState.compact(
                      icon: NightshadeIcons.target,
                      title: 'No target selected',
                      body:
                          'Search for an object or enter coordinates to begin '
                          'framing.',
                    ),
            ),

            _stepDivider(colors),

            // Step 2: frame
            _StepRow(
              number: 2,
              title: 'Frame',
              status: hasSurveyImage
                  ? StatusPillStatus.success
                  : StatusPillStatus.inactive,
              statusValue: hasSurveyImage ? 'Loaded' : 'Pending',
              colors: colors,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Survey Source',
                    style: NightshadeTypography.caption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: NightshadeTokens.spaceXs),
                  NightshadeDropdown(
                    isExpanded: true,
                    value: framingState.surveySource.name,
                    items: SurveySource.values.map((s) => s.name).toList(),
                    itemLabels:
                        SurveySource.values.map((s) => s.displayName).toList(),
                    onChanged: (name) {
                      if (name == null) return;
                      final source =
                          SurveySource.values.firstWhere((s) => s.name == name);
                      ref
                          .read(framingProvider.notifier)
                          .setSurveySource(source);
                    },
                  ),
                  const SizedBox(height: NightshadeTokens.spaceMd),
                  Text(
                    'Preview field of view',
                    style: NightshadeTypography.caption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: NightshadeTokens.spaceXs),
                  FramingPreviewFovSlider(
                    colors: colors,
                    value: framingState.previewFovDegrees,
                    hasEquipment: hasEquipment,
                    equipmentFov: equipment?.equipment?.fovWidthDeg,
                    onChanged: (value) {
                      ref.read(framingProvider.notifier).setPreviewFov(value);
                    },
                  ),
                ],
              ),
            ),

            _stepDivider(colors),

            // Step 3: solve current frame
            _StepRow(
              number: 3,
              title: 'Solve latest camera frame',
              status: (_lastSolve?.result?.success ?? false)
                  ? StatusPillStatus.success
                  : (_lastSolve?.error != null ||
                          _lastSolve?.solverMissing == true
                      ? StatusPillStatus.error
                      : StatusPillStatus.inactive),
              statusValue:
                  (_lastSolve?.result?.success ?? false) ? 'Solved' : 'Ready',
              colors: colors,
              child: _SolveStep(
                colors: colors,
                isSolving: _isSolving,
                canSolve:
                    hasTarget && hasCameraFrame && hasSolver && !_isSolving,
                hasTarget: hasTarget,
                hasCameraFrame: hasCameraFrame,
                hasSolver: hasSolver,
                outcome: _lastSolve,
                onSolve: _solveCurrentFrame,
              ),
            ),

            _stepDivider(colors),

            // Step 4: GoTo & frame
            _StepRow(
              number: 4,
              statusKey: framingGotoStatusKey,
              title: 'GoTo & Frame',
              status: !hasTarget
                  ? StatusPillStatus.inactive
                  : (!canSlew || isBelowHorizon
                      // A target but no usable mount (or a target under the
                      // ground): the step cannot run as-is, and saying so is the
                      // point. 'Ready' here was a lie.
                      ? StatusPillStatus.warning
                      : StatusPillStatus.active),
              // Terse on purpose: these read in parallel down the rail and fit
              // without ellipsizing. The full instruction is not lost — the step
              // body spells it out directly beneath.
              statusValue: !hasTarget
                  ? 'No target'
                  : !isMountConnected
                      ? 'No mount'
                      : isMountParked
                          ? 'Parked'
                          : isBelowHorizon
                              ? 'Below horizon'
                              : 'Ready',
              colors: colors,
              child: hasTarget
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: SlewDropdownButton(
                            key: FramingTutorialKeys.slewBtn,
                            // Slew to where the reticle was dragged, not the
                            // view center — this is the payoff of the aim
                            // model.
                            ra: aimTarget!.raHours,
                            dec: aimTarget.decDegrees,
                            targetName: target.name,
                            targetRotation: framingState.rotation != 0
                                ? framingState.rotation
                                : null,
                            icon: NightshadeIcons.compass,
                            label: 'Slew to Target',
                            // Without this the button stayed live over a parked
                            // mount and every click was swallowed in silence.
                            isEnabled: canSlew,
                          ),
                        ),
                        // The disabled button explains itself instead of
                        // swallowing the click with no feedback at all.
                        if (!isMountConnected) ...[
                          const SizedBox(height: NightshadeTokens.spaceXs),
                          Text(
                            'Connect the mount in Equipment to enable slewing.',
                            style: NightshadeTypography.caption.copyWith(
                              color: colors.warning,
                            ),
                          ),
                        ] else if (isMountParked) ...[
                          const SizedBox(height: NightshadeTokens.spaceXs),
                          Text(
                            'The mount is parked. Unpark it (Imaging → Mount) '
                            'before slewing.',
                            style: NightshadeTypography.caption.copyWith(
                              color: colors.warning,
                            ),
                          ),
                        ],
                        // Advisory, and shown even when the slew is allowed: the
                        // mount will happily drive into the ground.
                        if (isBelowHorizon) ...[
                          const SizedBox(height: NightshadeTokens.spaceXs),
                          Text(
                            '${target.name.isEmpty ? 'The target' : target.name} '
                            'is ${targetAltitudeDeg.toStringAsFixed(1)}° below '
                            'the horizon right now.',
                            style: NightshadeTypography.caption.copyWith(
                              color: colors.warning,
                            ),
                          ),
                        ],
                      ],
                    )
                  : Text(
                      'Resolve a target above to enable slewing.',
                      style: NightshadeTypography.caption.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
            ),
          ],
        ));
  }

  /// Current altitude of [target] in degrees, or `null` when the app has no
  /// usable observing site.
  ///
  /// (0, 0) is the app's "no location set" sentinel — the same one the
  /// coordinates card uses — and reporting an altitude from it would be
  /// inventing a horizon in the Gulf of Guinea.
  double? _targetAltitudeDeg(FramingTarget? target) {
    if (target == null) return null;
    final settings = ref.watch(appSettingsProvider).valueOrNull;
    if (settings == null) return null;
    if (!settings.hasObserverLocation) return null;
    final (alt, _) = calculateCurrentAltAz(
      raHours: target.raHours,
      decDegrees: target.decDegrees,
      latitudeDeg: settings.latitude,
      longitudeDeg: settings.longitude,
      time: DateTime.now(),
    );
    return alt;
  }

  Widget _stepDivider(NightshadeColors colors) => Padding(
        padding: const EdgeInsets.symmetric(vertical: NightshadeTokens.spaceMd),
        child: Divider(height: 1, color: colors.border),
      );

  /// Solve the latest real camera exposure against the resolved target. Survey
  /// cutouts already have known sky coordinates and are not evidence of where
  /// the mount is actually pointing; solving them made this step look useful
  /// while measuring nothing about the user's rig.
  Future<void> _solveCurrentFrame() async {
    if (_isSolving) return;

    final framingState = ref.read(framingProvider);
    // The solve measures the mount's offset from where it will be COMMANDED
    // to point — the aim — so the hint and the reported delta both reference
    // the dragged reticle position, not the view center.
    final target = framingState.effectiveAimTarget;
    final cameraFrame = ref.read(currentImageProvider);
    final imagePath = cameraFrame?.filePath;

    if (target == null || imagePath == null) {
      // The button is disabled in this state; this guard exists so a stray
      // call can never silently no-op without explanation.
      if (mounted) {
        context.showWarningSnackBar(
          target == null
              ? 'Resolve a target before solving.'
              : 'Capture a camera frame before solving.',
        );
      }
      return;
    }

    final backend = ref.read(backendProvider);
    final revision = ++_solveRevision;
    setState(() {
      _isSolving = true;
      _lastSolve = null;
    });

    try {
      final solver = ref.read(plateSolveServiceProvider);
      // Hint from where the telescope IS, read at click time, not from where
      // the operator wants it to be. The target is resolved once and then
      // outlives every slew of the session: the owner's 03:21 solves hinted
      // from coordinates hours and a polar alignment old, and ASTAP answered
      // "No solution found" in a second. The mount's own report is the same
      // source the automatic post-capture solve hints from, and it is right by
      // construction. With no mount, the target is the only guess there is —
      // and the native solver widens and then goes blind either way.
      final mountState = ref.read(mountStateProvider);
      final mountKnowsWhereItPoints =
          mountState.connectionState == DeviceConnectionState.connected &&
              mountState.ra != null &&
              mountState.dec != null;
      final result = await solver.solveWithFallback(
        imagePath: imagePath,
        // MountState reports RA in HOURS, which is what this parameter takes.
        hintRaHours: mountKnowsWhereItPoints ? mountState.ra! : target.raHours,
        hintDecDegrees:
            mountKnowsWhereItPoints ? mountState.dec! : target.decDegrees,
        searchRadiusDegrees: 5.0,
      );

      if (!_ownsSolve(backend, revision)) return;
      setState(() {
        _isSolving = false;
        _lastSolve = _SolveOutcome.solved(result, target);
      });

      if (!mounted) return;
      if (result.success) {
        context.showSuccessSnackBar(
          'Frame solved in ${result.solveTimeSecs.toStringAsFixed(1)}s',
        );
      } else {
        context.showErrorSnackBar(
          result.error ?? 'Plate solve failed',
        );
      }
    } on SolverNotAvailableError {
      if (!_ownsSolve(backend, revision)) return;
      setState(() {
        _isSolving = false;
        _lastSolve = const _SolveOutcome.noSolver();
      });
    } catch (e) {
      if (!_ownsSolve(backend, revision)) return;
      setState(() {
        _isSolving = false;
        _lastSolve = _SolveOutcome.failed(e.toString());
      });
      if (!mounted) return;
      context.showErrorSnackBar('Solve failed: $e');
    }
  }

  bool _ownsSolve(NightshadeBackend backend, int revision) =>
      mounted &&
      revision == _solveRevision &&
      identical(ref.read(backendProvider), backend);
}

/// One numbered step: a leading index badge, a title, a trailing [StatusPill],
/// and the step's body content.
class _StepRow extends StatelessWidget {
  final int number;
  final String title;
  final StatusPillStatus status;
  final String statusValue;
  final NightshadeColors colors;
  final Widget child;

  /// Optional key on the readiness pill. Several steps share pill wording
  /// ('Ready'), so a test that means THIS step's badge needs to be able to say
  /// so rather than counting matches across the rail.
  final Key? statusKey;

  const _StepRow({
    required this.number,
    required this.title,
    required this.status,
    required this.statusValue,
    required this.colors,
    required this.child,
    this.statusKey,
  });

  @override
  Widget build(BuildContext context) {
    final isDone = status == StatusPillStatus.success;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _StepBadge(number: number, isDone: isDone, colors: colors),
            const SizedBox(width: NightshadeTokens.spaceSm),
            Expanded(
              child: Text(
                title,
                style: NightshadeTypography.eyebrow.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            // Value-only pill: the step title to the left already names what
            // this readiness state refers to, so an empty label keeps the pill
            // reading 'Resolved' / 'Loaded' / 'Ready' rather than repeating the
            // step name. (StatusPill renders value-only when label is empty.)
            //
            // Flexible, because a non-flex child of a Row is given its intrinsic
            // width and cannot shrink: a longer status value than the rail could
            // fit overflowed the row (by 82 px on a phone in landscape and still
            // 39 px in the 254 px DESKTOP sidebar) instead of ellipsizing.
            // StatusPill already wraps its own text in Flexible + ellipsis, so it
            // only ever needed a bounded width to do the right thing.
            Flexible(
              child: StatusPill(
                key: statusKey,
                icon: isDone ? NightshadeIcons.check : NightshadeIcons.circle,
                label: '',
                value: statusValue,
                status: status,
              ),
            ),
          ],
        ),
        const SizedBox(height: NightshadeTokens.spaceSm),
        // Small left inset to set the step body off from the rail edge. Kept
        // modest (spaceMd) rather than space2xl: a larger inset left the reused
        // FramingPreviewFovSlider too little room and overflowed the narrow
        // (250-500px) framing sidebar the rail is mounted in.
        Padding(
          padding: const EdgeInsets.only(
            left: NightshadeTokens.spaceMd,
          ),
          child: child,
        ),
      ],
    );
  }
}

/// The circular step index, which becomes a filled check once the step is done.
class _StepBadge extends StatelessWidget {
  final int number;
  final bool isDone;
  final NightshadeColors colors;

  const _StepBadge({
    required this.number,
    required this.isDone,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final fill = isDone ? colors.success : colors.surfaceElevated;
    final fg = isDone ? colors.onPrimary : colors.textSecondary;
    final borderColor = isDone ? colors.success : colors.border;
    return Container(
      width: NightshadeTokens.iconLg,
      height: NightshadeTokens.iconLg,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: borderColor),
      ),
      child: isDone
          ? Icon(NightshadeIcons.check,
              size: NightshadeTokens.iconXs, color: fg)
          : Text(
              '$number',
              style: NightshadeTypography.labelSm.copyWith(color: fg),
            ),
    );
  }
}

/// Step 1 body: resolved target name + monospace RA/Dec readout.
class _TargetSummary extends StatelessWidget {
  final NightshadeColors colors;
  final FramingTarget target;

  const _TargetSummary({required this.colors, required this.target});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          target.name,
          style: NightshadeTypography.bodyMedium.copyWith(
            color: colors.textPrimary,
          ),
        ),
        if (target.catalogId != null && target.catalogId != target.name)
          Padding(
            padding: const EdgeInsets.only(top: NightshadeTokens.spaceXs),
            child: Text(
              target.catalogId!,
              style: NightshadeTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
          ),
        const SizedBox(height: NightshadeTokens.spaceSm),
        _CoordLine(label: 'RA', value: target.raFormatted, colors: colors),
        const SizedBox(height: NightshadeTokens.spaceXs),
        _CoordLine(label: 'Dec', value: target.decFormatted, colors: colors),
      ],
    );
  }
}

/// A label + monospace value coordinate line (tabular figures so updating
/// numbers don't shift the layout).
class _CoordLine extends StatelessWidget {
  final String label;
  final String value;
  final NightshadeColors colors;

  const _CoordLine({
    required this.label,
    required this.value,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 32,
          child: Text(
            label,
            style: NightshadeTypography.caption.copyWith(
              color: colors.textMuted,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: NightshadeTypography.monoSm.copyWith(
              color: colors.textPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

/// Step 3 body: the solve button, its preconditions, and the inline outcome
/// (banner / alert).
class _SolveStep extends StatelessWidget {
  final NightshadeColors colors;
  final bool isSolving;
  final bool canSolve;
  final bool hasTarget;
  final bool hasCameraFrame;
  final bool hasSolver;
  final _SolveOutcome? outcome;
  final VoidCallback onSolve;

  const _SolveStep({
    required this.colors,
    required this.isSolving,
    required this.canSolve,
    required this.hasTarget,
    required this.hasCameraFrame,
    required this.hasSolver,
    required this.outcome,
    required this.onSolve,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: NightshadeButton(
            label: 'Solve latest camera frame',
            icon: NightshadeIcons.crosshair,
            variant: ButtonVariant.secondary,
            isLoading: isSolving,
            onPressed: canSolve ? onSolve : null,
          ),
        ),
        if (!hasTarget || !hasCameraFrame)
          Padding(
            padding: const EdgeInsets.only(top: NightshadeTokens.spaceXs),
            child: Text(
              !hasTarget
                  ? 'Resolve a target to solve.'
                  : 'Capture a camera frame to measure the mount position.',
              style: NightshadeTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
          ),
        if (outcome != null) ...[
          const SizedBox(height: NightshadeTokens.spaceMd),
          _SolveOutcomeView(colors: colors, outcome: outcome!),
        ] else if (hasTarget && hasCameraFrame && !hasSolver) ...[
          const SizedBox(height: NightshadeTokens.spaceMd),
          const PlateSolverRequiredBanner(
            contextMessage:
                'The framing wizard solves the latest camera exposure to '
                'measure how far the mount is from your target. Set up '
                'ASTAP (or Astrometry.net) to enable this step.',
          ),
        ],
      ],
    );
  }
}

/// Renders the result of a solve attempt: the required-solver banner, a plain
/// error alert, or a success alert with the RA/Dec delta versus the target.
class _SolveOutcomeView extends StatelessWidget {
  final NightshadeColors colors;
  final _SolveOutcome outcome;

  const _SolveOutcomeView({required this.colors, required this.outcome});

  @override
  Widget build(BuildContext context) {
    if (outcome.solverMissing) {
      return const PlateSolverRequiredBanner(
        contextMessage:
            'No plate solver is reachable. Set up ASTAP (or Astrometry.net) '
            'to solve the latest camera frame.',
      );
    }

    if (outcome.error != null) {
      return NightshadeBanner(
          title: 'Solve failed',
          message: outcome.error!,
          tone: BannerTone.error);
    }

    final result = outcome.result!;
    if (!result.success) {
      return NightshadeBanner(
          title: 'Plate solve did not converge',
          message: result.error ??
              'The solver ran but could not find a solution for this frame.',
          tone: BannerTone.warning);
    }

    final against = outcome.against;
    final deltaMessage = against != null
        ? _formatDelta(result: result, target: against)
        : 'Solved center: '
            '${CoordinateFormat.ra(result.ra, seconds: SecondsPrecision.integerRounded)} '
            '${CoordinateFormat.dec(result.dec, seconds: SecondsPrecision.integerRounded)}';

    return NightshadeBanner(
        title: 'Frame solved', message: deltaMessage, tone: BannerTone.success);
  }

  /// Human-readable offset between the solved center and the target, plus the
  /// solved coordinates. RA delta is cos(dec)-scaled to a true angular offset.
  String _formatDelta({
    required PlateSolveResult result,
    required FramingTarget target,
  }) {
    final decRad = target.decDegrees * (math.pi / 180.0);
    final cosDec = math.cos(decRad).abs();

    // RA difference in hours, wrapped to the shortest arc, converted to degrees
    // then scaled by cos(dec) to an on-sky angle.
    var raDiffHours = result.ra - target.raHours;
    while (raDiffHours > 12.0) {
      raDiffHours -= 24.0;
    }
    while (raDiffHours < -12.0) {
      raDiffHours += 24.0;
    }
    final raDeltaDeg = (raDiffHours * 15.0) * cosDec;
    final decDeltaDeg = result.dec - target.decDegrees;

    final raDeltaArcmin = raDeltaDeg.abs() * 60.0;
    final decDeltaArcmin = decDeltaDeg.abs() * 60.0;

    final raDir = raDeltaDeg >= 0 ? 'E' : 'W';
    final decDir = decDeltaDeg >= 0 ? 'N' : 'S';

    return 'Solved center '
        '${CoordinateFormat.ra(result.ra, seconds: SecondsPrecision.integerRounded)} '
        '${CoordinateFormat.dec(result.dec, seconds: SecondsPrecision.integerRounded)}\n'
        'Offset from target: '
        '${raDeltaArcmin.toStringAsFixed(1)}\' $raDir, '
        '${decDeltaArcmin.toStringAsFixed(1)}\' $decDir';
  }
}
