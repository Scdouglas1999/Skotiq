import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

// Reuse the imaging screen's canonical decode+paint widget. It already watches
// `stretchedImageProvider` (which the first-light orchestrator populates during
// the stretching stage) and falls back to the captured frame's RGBA display
// buffer, so the first-light preview renders identically to the manual snapshot
// path. It is not exported from the package barrel, but lives in the same
// package, so a relative import is the correct reuse seam.
import '../../screens/imaging/widgets/image_display.dart';
import '../troubleshooter/connection_troubleshooter_dialog.dart';

/// The "wow-moment" first-light flow dialog.
///
/// Driven entirely by [firstLightControllerProvider] (the C8 controller +
/// orchestrator). The dialog is a thin, mounted-guarded view over
/// [FirstLightState]: it never reaches into the imaging pipeline itself.
///
/// Flow surfaces:
///   * idle      → intro panel (what-happens explainer + exposure field + Start)
///   * running   → vertical stepper of the four pipeline phases
///   * success   → stretched preview + annotation summary + next-step actions
///   * failed    → error alert + retry (and Troubleshoot when it's a connection
///                 failure)
///
/// The share entry point is explicitly out of scope here (a later feature).
class FirstLightFlowDialog extends ConsumerWidget {
  const FirstLightFlowDialog({super.key});

  /// Open the first-light flow dialog. Resets the controller to idle on
  /// dismissal so a subsequent open starts from a clean intro panel rather
  /// than a stale terminal state.
  static Future<void> show(BuildContext context) async {
    final container = ProviderScope.containerOf(context, listen: false);
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const FirstLightFlowDialog(),
    );
    // The dialog is gone; clear any terminal state so the next launch is fresh.
    // ProviderScope is read via the container captured before the await so we
    // don't touch a possibly-unmounted BuildContext.
    container.read(firstLightControllerProvider.notifier).reset();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(firstLightControllerProvider);

    // Dismissing mid-run orphans the capture: the exposure keeps running on the
    // sensor with nothing holding a handle on it. PopScope covers the back
    // button and the modal barrier but NOT the header close button —
    // SkotiqDialog pops the route directly, which PopScope does not
    // intercept — so `closeEnabled` gates that separately. The exit mid-run is
    // the footer's Stop capture, which actually aborts at the camera.
    return PopScope(
      canPop: !state.isRunning,
      child: SkotiqDialog(
        title: 'Your first light',
        icon: LucideIcons.sparkles,
        closeEnabled: !state.isRunning,
        width: 720,
        // No fixed height: the body is adaptive across the four flow surfaces.
        actions: _actionsFor(context, ref, state),
        child: _FirstLightBody(state: state),
      ),
    );
  }

  List<Widget>? _actionsFor(
    BuildContext context,
    WidgetRef ref,
    FirstLightState state,
  ) {
    switch (state.phase) {
      case FirstLightPhase.success:
        return [
          SkotiqButton(
            label: 'Done',
            variant: ButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop(),
          ),
          SkotiqButton(
            label: 'View in Imaging',
            icon: LucideIcons.image,
            onPressed: () {
              Navigator.of(context).pop();
              context.go('/imaging');
            },
          ),
        ];
      case FirstLightPhase.failed:
        return [
          if (_isConnectionFailure(state.errorMessage))
            SkotiqButton(
              label: 'Troubleshoot connection',
              variant: ButtonVariant.outline,
              icon: LucideIcons.wrench,
              onPressed: () => _openTroubleshooter(context, ref, state),
            ),
          SkotiqButton(
            label: 'Try again',
            icon: LucideIcons.refreshCw,
            onPressed: () =>
                ref.read(firstLightControllerProvider.notifier).reset(),
          ),
        ];
      case FirstLightPhase.exposing:
      case FirstLightPhase.stretching:
      case FirstLightPhase.solving:
      case FirstLightPhase.annotating:
        // A progress modal whose only exit does not cancel is the shape that
        // costs a night: the operator closed it, the exposure kept running,
        // and the camera stayed busy. This is the one exit while a stage is
        // in flight, and it aborts at the camera rather than just hiding the
        // dialog.
        return [
          SkotiqButton(
            label: 'Stop capture',
            variant: ButtonVariant.outline,
            icon: LucideIcons.x,
            onPressed: () =>
                ref.read(firstLightControllerProvider.notifier).cancel(),
          ),
        ];
      case FirstLightPhase.idle:
        // idle has its own inline Start button.
        return null;
    }
  }

  /// A failure is treatable by the connection troubleshooter when it is a
  /// device-connectivity problem rather than a downstream pipeline error
  /// (capture/stretch/solve/annotate). The orchestrator's
  /// `_requireCameraConnected` stage emits the canonical "No camera connected"
  /// message; we also recognise the generic connection markers the device
  /// error pipeline surfaces so a mid-flow disconnect routes to the same place.
  static bool _isConnectionFailure(String? message) {
    if (message == null || message.isEmpty) return false;
    final m = message.toLowerCase();
    return m.contains('no camera connected') ||
        m.contains('camera disconnected') ||
        m.contains('not connected') ||
        m.contains('connection refused') ||
        m.contains('connection reset') ||
        m.contains('timed out') ||
        m.contains('unreachable') ||
        m.contains('rpc server unavailable');
  }

  /// Opens the connection troubleshooter (C12) over the first-light dialog,
  /// handing it the camera's actual driver protocol and the raw failure string
  /// so the user gets a protocol-specific remediation playbook with the verbatim
  /// driver error preserved.
  ///
  /// The troubleshooter resolves to `true` when the user asks to retry. In that
  /// case we re-run the whole first-light flow at the same exposure length,
  /// reusing the controller exactly as the "Try again" action does — so a fixed
  /// connection flows straight back into capture without the user re-deriving
  /// anything.
  Future<void> _openTroubleshooter(
    BuildContext context,
    WidgetRef ref,
    FirstLightState state,
  ) async {
    final controller = ref.read(firstLightControllerProvider.notifier);
    // Default to native if the camera driver is unknown (e.g. no camera was
    // connected when the flow started): native is the most common first-light
    // setup and its guidance is the safest generic camera advice.
    final driverType = state.cameraDriverType ?? DriverType.native;

    final retry = await ConnectionTroubleshooterDialog.show(
      context,
      deviceType: DeviceType.camera,
      driverType: driverType,
      rawError: state.errorMessage,
    );

    if (!context.mounted || !retry) return;

    // Re-run at the exposure the user chose; fall back to the
    // intro panel's default when the failed state somehow carried none, so the
    // retry always has a valid positive exposure. Not awaited: the dialog
    // reactively follows the streamed FirstLightState, exactly like the intro
    // panel's Start button.
    final exposure =
        state.exposureSeconds ?? _IntroPanelState._defaultExposureSeconds;
    unawaited(controller.run(exposureSeconds: exposure));
  }
}

/// Switches between the four flow surfaces. Kept as a separate widget so each
/// surface rebuilds against the watched [FirstLightState] without re-running
/// the dialog scaffold.
class _FirstLightBody extends ConsumerWidget {
  const _FirstLightBody({required this.state});

  final FirstLightState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (state.phase) {
      case FirstLightPhase.idle:
        return const _IntroPanel();
      case FirstLightPhase.exposing:
      case FirstLightPhase.stretching:
      case FirstLightPhase.solving:
      case FirstLightPhase.annotating:
        return _ProgressPanel(state: state);
      case FirstLightPhase.success:
        return _SuccessPanel(state: state);
      case FirstLightPhase.failed:
        return _FailurePanel(state: state);
    }
  }
}

// Intro panel

class _IntroPanel extends ConsumerStatefulWidget {
  const _IntroPanel();

  @override
  ConsumerState<_IntroPanel> createState() => _IntroPanelState();
}

class _IntroPanelState extends ConsumerState<_IntroPanel> {
  static const _defaultExposureSeconds = 5.0;

  /// Hard ceiling on the guided first-light exposure, in seconds.
  ///
  /// This panel is the ONLY producer of the exposure the orchestrator runs and
  /// nothing downstream bounds it, so the bound has to live here: the flow has
  /// no cancel path, and one extra keystroke in an unbounded field commits the
  /// camera for days. Two minutes is far longer than a first light needs while
  /// staying inside the panel's own "a few seconds" promise.
  static const _maxExposureSeconds = 120.0;

  late final TextEditingController _exposureController;
  String? _exposureError;

  @override
  void initState() {
    super.initState();
    _exposureController = TextEditingController(
      text: _defaultExposureSeconds.toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    _exposureController.dispose();
    super.dispose();
  }

  /// The entered exposure, or the reason it cannot be run.
  ///
  /// Both bounds live here rather than only in the formatter so the refusal is
  /// visible: the field keeps whatever the user typed and the error names the
  /// limit, instead of silently rewriting the number under their cursor.
  ({double? seconds, String? error}) _parseExposure() {
    final raw = _exposureController.text.trim();
    final value = double.tryParse(raw);
    if (value == null || value <= 0) {
      return (
        seconds: null,
        error: 'Enter an exposure length greater than 0 seconds.',
      );
    }
    if (value > _maxExposureSeconds) {
      return (
        seconds: null,
        error:
            'First light is capped at ${_maxExposureSeconds.toStringAsFixed(0)} '
            'seconds. Enter a shorter exposure, or take a long one from the '
            'Imaging screen where you can stop it.',
      );
    }
    return (seconds: value, error: null);
  }

  void _start() {
    final parsed = _parseExposure();
    final exposure = parsed.seconds;
    if (exposure == null) {
      setState(() => _exposureError = parsed.error);
      return;
    }
    setState(() => _exposureError = null);
    // Fire the flow; the controller guards against re-entrancy and never
    // throws (failures surface as FirstLightPhase.failed state). We do not
    // await here — the dialog reactively follows the streamed state.
    ref
        .read(firstLightControllerProvider.notifier)
        .run(exposureSeconds: exposure);
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SkotiqAlert(
          severity: SkotiqAlertSeverity.info,
          title: "Let's take your first picture of the sky",
          message:
              'In one click Skotiq will take a short exposure, stretch it '
              'for a punchy preview, plate-solve where the telescope is '
              'pointing, and label the objects it finds. Make sure your camera '
              'is connected on the Equipment screen first.',
        ),
        const SizedBox(height: SkotiqTokens.spaceXl),
        Text(
          'Exposure length',
          style: SkotiqTypography.label.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        SkotiqTextField(
          controller: _exposureController,
          hint: '5',
          prefixIcon: LucideIcons.timer,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          suffix: 'seconds',
          errorText: _exposureError,
          onChanged: (_) {
            if (_exposureError != null) {
              setState(() => _exposureError = null);
            }
          },
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Text(
          'A few seconds is plenty for a first light — long enough to capture '
          'stars, short enough to finish quickly. '
          '${_maxExposureSeconds.toStringAsFixed(0)} seconds is the most this '
          'flow will run; longer subs belong on the Imaging screen.',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: SkotiqTokens.spaceXl),
        Align(
          alignment: Alignment.centerRight,
          child: SkotiqButton(
            label: 'Start capture',
            icon: LucideIcons.play,
            onPressed: _start,
          ),
        ),
      ],
    );
  }
}

// Progress panel — vertical stepper

/// One phase row in the running stepper.
enum _StepStatus { done, active, pending }

class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({required this.state});

  final FirstLightState state;

  /// The ordered visible phases. `solving` and `annotating` are real pipeline
  /// stages; they always appear so the user sees the full journey even when
  /// the flow legitimately ends early (no solver configured) — in that case
  /// the flow jumps to `success` and this panel is never the terminal view.
  static const _phases = <FirstLightPhase>[
    FirstLightPhase.exposing,
    FirstLightPhase.stretching,
    FirstLightPhase.solving,
    FirstLightPhase.annotating,
  ];

  static String _labelFor(FirstLightPhase phase) {
    switch (phase) {
      case FirstLightPhase.exposing:
        return 'Capturing exposure';
      case FirstLightPhase.stretching:
        return 'Stretching for preview';
      case FirstLightPhase.solving:
        return 'Plate-solving the field';
      case FirstLightPhase.annotating:
        return 'Labelling objects';
      case FirstLightPhase.idle:
      case FirstLightPhase.success:
      case FirstLightPhase.failed:
        return '';
    }
  }

  _StepStatus _statusFor(FirstLightPhase phase) {
    final currentIndex = _phases.indexOf(state.phase);
    final phaseIndex = _phases.indexOf(phase);
    if (currentIndex < 0) {
      // Defensive: only reached if a non-running phase slips through; treat
      // everything as pending rather than mis-rendering.
      return _StepStatus.pending;
    }
    if (phaseIndex < currentIndex) return _StepStatus.done;
    if (phaseIndex == currentIndex) return _StepStatus.active;
    return _StepStatus.pending;
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Working on it…',
          style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: SkotiqTokens.spaceXl),
        for (final phase in _phases)
          _StepRow(
            label: _labelFor(phase),
            status: _statusFor(phase),
            isLast: phase == _phases.last,
          ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.label,
    required this.status,
    required this.isLast,
  });

  final String label;
  final _StepStatus status;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    final (dotColor, dotVariant) = switch (status) {
      _StepStatus.done => (colors.success, StatusDotVariant.static),
      _StepStatus.active => (colors.primary, StatusDotVariant.attention),
      _StepStatus.pending => (colors.textMuted, StatusDotVariant.static),
    };

    final labelColor = switch (status) {
      _StepStatus.done => colors.textSecondary,
      _StepStatus.active => colors.textPrimary,
      _StepStatus.pending => colors.textMuted,
    };

    return Padding(
      padding: EdgeInsets.only(
        bottom: isLast ? 0 : SkotiqTokens.spaceLg,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: SkotiqTokens.iconMd,
            child: Center(
              child: status == _StepStatus.done
                  ? Icon(
                      LucideIcons.check,
                      size: SkotiqTokens.iconSm,
                      color: colors.success,
                    )
                  : StatusDot(color: dotColor, variant: dotVariant),
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: SkotiqTypography.body.copyWith(color: labelColor),
                ),
                if (status == _StepStatus.active) ...[
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  const SkotiqProgressBar(
                    value: 0,
                    indeterminate: true,
                    style: SkotiqProgressStyle.thin,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Success panel — preview + annotation summary

class _SuccessPanel extends ConsumerWidget {
  const _SuccessPanel({required this.state});

  final FirstLightState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final captured = ref.watch(currentImageProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _PreviewCard(captured: captured),
        const SizedBox(height: SkotiqTokens.spaceLg),
        _AnnotationSummary(state: state),
        if (state.solveResult != null) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          _SolveDetails(result: state.solveResult!),
        ],
        const SizedBox(height: SkotiqTokens.spaceLg),
        Text(
          state.solveResult != null
              ? 'That field is now labelled in the imaging preview. Open it to '
                  'explore your first light.'
              : 'Your first light is captured and stretched. Open it in the '
                  'imaging preview to take a closer look.',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.captured});

  final CapturedImageData? captured;

  /// Fixed preview height; the decoded frame is fit-to-box inside it.
  static const _previewHeight = 320.0;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return SkotiqCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: SkotiqTokens.borderRadiusMd,
        child: SizedBox(
          height: _previewHeight,
          width: double.infinity,
          child: Container(
            color: colors.background,
            alignment: Alignment.center,
            child: captured == null
                ? _PreviewUnavailable(colors: colors)
                : FittedBox(
                    fit: BoxFit.contain,
                    // ImageDisplayWidget paints the decoded frame at native
                    // size scaled by zoomLevel; wrapping it in a FittedBox at
                    // zoom 1.0 scales the whole frame down to fit the card
                    // without distortion. It watches stretchedImageProvider,
                    // so it shows the stretched preview the orchestrator
                    // produced.
                    child: SizedBox(
                      width: captured!.width.toDouble(),
                      height: captured!.height.toDouble(),
                      child: ImageDisplayWidget(
                        imageData: captured!,
                        zoomLevel: 1.0,
                        panOffset: Offset.zero,
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _PreviewUnavailable extends StatelessWidget {
  const _PreviewUnavailable({required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: SkotiqTokens.paddingXl,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            LucideIcons.imageOff,
            size: SkotiqTokens.iconXl,
            color: colors.textMuted,
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          Text(
            'The captured frame is no longer in memory.',
            textAlign: TextAlign.center,
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

/// The annotation summary chip row (objects labelled) or, when the solver was
/// not configured, the warning banner with a "Set up solver" link.
class _AnnotationSummary extends ConsumerWidget {
  const _AnnotationSummary({required this.state});

  final FirstLightState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);

    // No solve → the only legitimate non-error reason is "solver not
    // configured" (the orchestrator's positive early-out). Surface the warning
    // banner + the setup link the brief specifies.
    if (state.solveResult == null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: SkotiqInlineBanner(
              severity: SkotiqAlertSeverity.warning,
              message:
                  state.note ?? FirstLightOrchestrator.solverNotConfiguredNote,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceMd),
          SkotiqButton(
            label: 'Set up solver',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            icon: LucideIcons.settings,
            onPressed: () {
              Navigator.of(context).pop();
              context.go('/settings/plate-solving');
            },
          ),
        ],
      );
    }

    // Solved → show how many objects were labelled. The annotation the
    // orchestrator built is published to currentAnnotationProvider.
    final annotation = ref.watch(currentAnnotationProvider);
    final count = annotation?.objects.length ?? 0;

    return Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceSm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _SummaryChip(
          icon: LucideIcons.checkCircle2,
          label: count == 1 ? '1 object labelled' : '$count objects labelled',
          color: colors.success,
        ),
        if (count == 0)
          Text(
            'The field solved, but no catalog objects fell inside it.',
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
          ),
      ],
    );
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: SkotiqDecorations.statusChip(color),
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: SkotiqTokens.iconSm, color: color),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            label,
            style: SkotiqTypography.labelSm.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// Compact read-out of where the telescope was pointing, from the solve.
class _SolveDetails extends StatelessWidget {
  const _SolveDetails({required this.result});

  final PlateSolveResult result;

  /// Format an RA value in hours (the solver returns degrees) as HHh MMm.
  static String _formatRa(double degrees) => CoordinateFormat.raHmFromDegrees(
        degrees,
        style: SexagesimalStyle.leadPlainLetters,
        minutes: MinutesPrecision.rounded,
      );

  static String _formatDec(double degrees) {
    final sign = degrees < 0 ? '-' : '+';
    final abs = degrees.abs();
    final d = abs.floor();
    final m = ((abs - d) * 60).round();
    if (m == 60) return '$sign${d + 1}° 00′';
    return '$sign$d° ${m.toString().padLeft(2, '0')}′';
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    final parts = <String>[
      'RA ${_formatRa(result.ra)}',
      'Dec ${_formatDec(result.dec)}',
      '${result.pixelScale.toStringAsFixed(2)}″/px',
    ];

    return Row(
      children: [
        Icon(
          LucideIcons.crosshair,
          size: SkotiqTokens.iconSm,
          color: colors.textMuted,
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: Text(
            parts.join('   •   '),
            style: SkotiqTypography.monoSm
                .copyWith(color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}

// Failure panel

class _FailurePanel extends StatelessWidget {
  const _FailurePanel({required this.state});

  final FirstLightState state;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SkotiqAlert(
          severity: SkotiqAlertSeverity.error,
          title: "First light didn't finish",
          message: state.errorMessage ??
              'Something went wrong during the first-light flow.',
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        Text(
          FirstLightFlowDialog._isConnectionFailure(state.errorMessage)
              ? 'This looks like a connection problem. Troubleshoot the '
                  'connection, then try again.'
              : 'You can fix the issue and run first light again from the top.',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}
