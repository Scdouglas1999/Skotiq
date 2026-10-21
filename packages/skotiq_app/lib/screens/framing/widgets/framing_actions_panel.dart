// The Telescope section of the Framing column: where the telescope will
// point, whether it can go there now, and the two pointing actions.
//
//   * Slew - the one SlewDropdownButton (slew, slew & center, slew, center &
//     rotate) to the frame center, gated on a connected, unparked mount. A
//     target below the horizon is flagged but not refused: the operator may
//     want the mount pre-pointed at something that has not risen yet.
//   * Solve latest camera frame - plate-solves the newest real camera
//     exposure against the frame center and reports the offset. A
//     SolverNotAvailableError shows the PlateSolverRequiredBanner.
//
// The readiness note on the title row is driven by the same predicate that
// enables the slew button, so it can never read "Ready" over a dead button.
// Errors are surfaced, never swallowed.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'package:skotiq_app/utils/snackbar_helper.dart';
import 'package:skotiq_app/widgets/plate_solver_required_banner.dart';
import 'package:skotiq_app/widgets/slew_dropdown_button.dart';
import '../../../widgets/tutorial_keys/framing_keys.dart';
import '../framing_altaz.dart';
import 'framing_panel_parts.dart';

/// The Telescope section's readiness note ('Ready', 'No mount', 'Parked').
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

/// The Telescope section: readiness, slew and solve.
///
/// Stateful so it can own the transient solve state (in-flight flag + last
/// outcome) without pushing it into the shared framing provider - the outcome
/// is purely presentational and scoped to this section's lifetime.
class FramingTelescopeSection extends ConsumerStatefulWidget {
  const FramingTelescopeSection({super.key});

  @override
  ConsumerState<FramingTelescopeSection> createState() =>
      _FramingTelescopeSectionState();
}

class _FramingTelescopeSectionState
    extends ConsumerState<FramingTelescopeSection> {
  bool _isSolving = false;
  _SolveOutcome? _lastSolve;
  int _solveRevision = 0;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
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
    final colors = SkotiqColors.of(context);
    final framingState = ref.watch(framingProvider);
    final solverDetection = ref.watch(plateSolverDetectionProvider);
    final solverPreference = ref.watch(plateSolverPreferenceProvider);

    final target = framingState.target;
    // The aim is where the telescope will actually point - the dragged
    // reticle's coordinates, or the view-center target when the box has not
    // been dragged. Slew, the solve hint and the horizon advisory read it; the
    // picked `target` only names the slew.
    final aimTarget = framingState.effectiveAimTarget;
    final hasTarget = target != null;
    final latestCameraFrame = ref.watch(currentImageProvider);
    final hasCameraFrame = latestCameraFrame?.filePath != null;
    final detection = solverDetection.valueOrNull;
    final preference = solverPreference.valueOrNull;
    final hasSolver = detection != null &&
        preference != null &&
        detection.supports(preference.choice);

    // The readiness note must come from the SAME predicate that enables the
    // slew button. [SlewDropdownButton] gates itself on the mount being
    // connected; a note driven by `hasTarget` alone once read a green "Ready"
    // over a button that swallowed every click in silence.
    final mountState = ref.watch(mountStateProvider);
    final isMountConnected =
        mountState.connectionState == DeviceConnectionState.connected;
    // A PARKED mount cannot GoTo - every driver refuses, most of them without
    // an error the UI ever sees. `isParked` defaults to true on an unknown
    // mount, so it is only consulted once the mount is connected.
    final isMountParked = isMountConnected && mountState.isParked;
    final canSlew = hasTarget && isMountConnected && !isMountParked;

    // Altitude is advisory, not a gate: a target below the horizon now will
    // rise, and the operator may want the mount pre-pointed. But "Ready" over
    // a target under the ground would be false, so the note says which it is.
    // Null means no configured site, in which case we claim nothing. Measured
    // at the AIM - the slew destination - not the view center.
    final targetAltitudeDeg = _targetAltitudeDeg(aimTarget);
    final isBelowHorizon = targetAltitudeDeg != null && targetAltitudeDeg < 0;

    // Terse on purpose: the note shares the title row and must not ellipsize
    // at the column's 250 px minimum. The line under the button spells it out.
    final String status;
    final Color statusColor;
    if (!hasTarget) {
      status = 'No target';
      statusColor = colors.textMuted;
    } else if (!isMountConnected) {
      status = 'No mount';
      statusColor = colors.warning;
    } else if (isMountParked) {
      status = 'Parked';
      statusColor = colors.warning;
    } else if (isBelowHorizon) {
      status = 'Below horizon';
      statusColor = colors.warning;
    } else {
      status = 'Ready';
      statusColor = colors.success;
    }

    return FramingPanelSection(
      title: 'Telescope',
      note: status,
      noteColor: statusColor,
      noteKey: framingGotoStatusKey,
      children: [
        if (hasTarget)
          SlewDropdownButton(
            key: FramingTutorialKeys.slewBtn,
            // Slew to where the reticle was dragged, not the view center.
            ra: aimTarget!.raHours,
            dec: aimTarget.decDegrees,
            targetName: target.name,
            targetRotation: framingState.rotation,
            defaultMode: SlewMode.slewAndCenter,
            // Without this the button stayed live over a parked mount and
            // every click was swallowed in silence.
            isEnabled: canSlew,
          ),
        // The disabled button explains itself instead of swallowing the
        // click with no feedback at all.
        if (!hasTarget)
          const FramingNote('Resolve a target above to enable slewing.')
        else if (!isMountConnected)
          FramingNote(
            'Connect the mount in Equipment to enable slewing.',
            color: colors.warning,
          )
        else if (isMountParked)
          FramingNote(
            'The mount is parked. Unpark it (Imaging → Mount) before '
            'slewing.',
            color: colors.warning,
          ),
        // Advisory, and shown even when the slew is allowed: the mount will
        // happily drive into the ground.
        if (hasTarget && isBelowHorizon)
          FramingNote(
            '${target.name.isEmpty ? 'The target' : target.name} is '
            '${targetAltitudeDeg.toStringAsFixed(1)}° below the horizon '
            'right now.',
            color: colors.warning,
          ),
        _SolveStep(
          colors: colors,
          isSolving: _isSolving,
          canSolve: hasTarget && hasCameraFrame && hasSolver && !_isSolving,
          hasTarget: hasTarget,
          hasCameraFrame: hasCameraFrame,
          hasSolver: hasSolver,
          outcome: _lastSolve,
          onSolve: _solveCurrentFrame,
        ),
      ],
    );
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

  bool _ownsSolve(SkotiqBackend backend, int revision) =>
      mounted &&
      revision == _solveRevision &&
      identical(ref.read(backendProvider), backend);
}

/// The solve action, its precondition line and the inline outcome.
class _SolveStep extends StatelessWidget {
  final SkotiqColors colors;
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
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SkotiqButton(
          label: 'Solve latest camera frame',
          icon: SkotiqIcons.crosshair,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          isLoading: isSolving,
          onPressed: canSolve ? onSolve : null,
        ),
        // With no target the section's own line already says what to do.
        if (hasTarget && !hasCameraFrame) ...[
          const SizedBox(height: kNightPanelRowGap),
          const FramingNote(
            'Capture a camera frame to measure the mount position.',
          ),
        ],
        if (outcome != null) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          _SolveOutcomeView(colors: colors, outcome: outcome!),
        ] else if (hasTarget && hasCameraFrame && !hasSolver) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          const PlateSolverRequiredBanner(
            contextMessage:
                'Framing solves the latest camera exposure to measure how '
                'far the mount is from your target. Set up ASTAP (or '
                'Astrometry.net) to enable this.',
          ),
        ],
      ],
    );
  }
}

/// Renders the result of a solve attempt: the required-solver banner, a plain
/// error alert, or a success alert with the RA/Dec delta versus the target.
class _SolveOutcomeView extends StatelessWidget {
  final SkotiqColors colors;
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
      return SkotiqBanner(
          title: 'Solve failed',
          message: outcome.error!,
          tone: BannerTone.error);
    }

    final result = outcome.result!;
    if (!result.success) {
      return SkotiqBanner(
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

    return SkotiqBanner(
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
