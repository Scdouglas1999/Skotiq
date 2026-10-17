import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/focus_model_curve_card.dart';
import '../../../widgets/focuser_backlash/focuser_backlash_offer.dart';
import '../../../widgets/focuser_controls.dart';
import 'panel_widgets.dart';

/// Gap between the manual-focus step-size chips, in logical pixels.
const double _stepChipGap = 6;

class FocusPanel extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const FocusPanel({super.key, required this.colors});

  @override
  ConsumerState<FocusPanel> createState() => _FocusPanelState();
}

class _FocusPanelState extends ConsumerState<FocusPanel> {
  // UI-only transient state (doesn't need to persist)
  bool _isRunningAutofocus = false;
  bool _isOfferingCalibration = false;
  ProviderSubscription<DeviceService>? _serviceSubscription;

  @override
  void initState() {
    super.initState();
    _serviceSubscription = ref.listenManual<DeviceService>(
      deviceServiceProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        if ((_isRunningAutofocus || _isOfferingCalibration) && mounted) {
          setState(() {
            _isRunningAutofocus = false;
            _isOfferingCalibration = false;
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _serviceSubscription?.close();
    super.dispose();
  }

  void _showGoToPositionDialog() {
    final focuserState = ref.read(focuserStateProvider);
    showDialog<void>(
      context: context,
      builder: (_) => GoToPositionDialog(
        initialPosition: focuserState.position ?? 0,
        // Null when the driver hasn't reported a travel limit; the dialog must
        // validate against the real max only when it is actually known rather
        // than fabricating a ceiling.
        maxPosition: focuserState.maxPosition,
        onSubmit: (position) =>
            ref.read(deviceServiceProvider).moveFocuserTo(position),
        // Awaited hardware stop, invoked when the user aborts a move that is
        // already in flight so the dialog never walks away from a driving
        // focuser.
        onHalt: () => ref.read(deviceServiceProvider).haltFocuser(),
      ),
    );
  }

  /// Run Autofocus, which may stop to offer a backlash measurement first.
  ///
  /// Shares the one interception in `focuser_backlash_offer.dart` with the
  /// focuser control strip, so the offer makes the same promises on both
  /// surfaces. Declining runs the focus immediately.
  Future<void> _runAutofocus() async {
    if (_isOfferingCalibration ||
        _isRunningAutofocus ||
        ref.read(deviceServiceProvider).isAutofocusRunning) {
      return;
    }
    setState(() => _isOfferingCalibration = true);
    try {
      await runWithBacklashOffer(context, ref, proceed: _startAutofocus);
    } finally {
      if (mounted) {
        setState(() => _isOfferingCalibration = false);
      }
    }
  }

  Future<void> _startAutofocus() async {
    final service = ref.read(deviceServiceProvider);
    setState(() => _isRunningAutofocus = true);

    try {
      final settings = ref.read(focusSettingsProvider);
      final result = await service.runAutofocus(
        exposureTime: settings.exposureTime,
        stepSize: settings.afStepSize,
        stepsOut: settings.stepsOut,
        method: settings.method,
        binning: 1,
        useSettingsDefaults: false,
      );

      if (mounted && _isCurrentService(service)) {
        context.showSuccessSnackBar(
            'Autofocus complete! Position: ${result.bestPosition}, HFR: ${result.bestHfr.toStringAsFixed(2)}');
      }
    } on AutofocusCancelledException {
      if (mounted && _isCurrentService(service)) {
        context.showInfoSnackBar('Autofocus cancelled');
      }
    } catch (e) {
      if (mounted && _isCurrentService(service)) {
        context.showErrorSnackBar('Autofocus failed: $e');
      }
    } finally {
      if (_isCurrentService(service)) {
        setState(() => _isRunningAutofocus = false);
      }
    }
  }

  bool _isCurrentService(DeviceService service) =>
      mounted && identical(ref.read(deviceServiceProvider), service);

  @override
  Widget build(BuildContext context) {
    final focuserState = ref.watch(focuserStateProvider);
    final cameraState = ref.watch(cameraStateProvider);
    final sessionState = ref.watch(sessionStateProvider);
    final focusSettings = ref.watch(focusSettingsProvider);
    final isConnected =
        focuserState.connectionState == DeviceConnectionState.connected;
    final currentPosition = focuserState.position ?? 0;
    final rawMaxPosition = focuserState.maxPosition;
    // A driver may not report a travel ceiling (null) or may report a bogus
    // negative one; treat both as "unknown" and show an honest marker rather
    // than inventing a limit the hardware never claimed.
    final hasKnownMax = rawMaxPosition != null && rawMaxPosition > 0;
    final positionSuffix = !isConnected
        ? ''
        : hasKnownMax
            ? ' / $rawMaxPosition'
            : ' / —';
    final temperature = focuserState.temperature;
    final isMoving = focuserState.isMoving;
    final autofocusRunning = sessionState.isAutofocusing || _isRunningAutofocus;
    final cameraConnected =
        cameraState.connectionState == DeviceConnectionState.connected;
    // Null until the persisted autofocus settings have loaded. The Curve fit
    // row renders disabled with an explicit "still loading" note in that
    // window rather than showing an empty control that looks like a broken or
    // unset choice.
    final curveFitting =
        ref.watch(appSettingsProvider).valueOrNull?.afCurveFitting;

    return SingleChildScrollView(
      // The SidePanel already pads its content by 16 (05 §15).
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Connection status
          if (!isConnected)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: SkotiqDecorations.emphasisSurface(
                widget.colors.warning,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.alertCircle,
                      size: 16, color: widget.colors.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'No focuser connected',
                      style: SkotiqTypography.caption
                          .copyWith(color: widget.colors.warning),
                    ),
                  ),
                ],
              ),
            ),

          // Manual Focus Section
          PanelSection(
            title: 'Manual focus',
            colors: widget.colors,
            child: Column(
              children: [
                // Position display
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Position',
                        style: SkotiqTypography.caption
                            .copyWith(color: widget.colors.textSecondary)),
                    Row(
                      children: [
                        Text(
                          // A disconnected focuser has no position, and that
                          // is an em dash, not '---'.
                          isConnected ? '$currentPosition' : '\u2014',
                          style: SkotiqTypography.readoutSm.copyWith(
                            color: isConnected
                                ? widget.colors.textPrimary
                                : widget.colors.textMuted,
                          ),
                        ),
                        Text(
                          positionSuffix,
                          style: SkotiqTypography.caption.copyWith(
                            color: widget.colors.textMuted,
                          ),
                        ),
                        if (isMoving)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: SizedBox(
                              width: 12,
                              height: 12,
                              child: SkotiqSpinner(
                                  size: 12, color: widget.colors.primary),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                if (temperature != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Temperature',
                            style: SkotiqTypography.caption
                                .copyWith(color: widget.colors.textSecondary)),
                        Text(
                          '${temperature.toStringAsFixed(1)}°C',
                          style: SkotiqTypography.caption
                              .copyWith(color: widget.colors.textPrimary),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 16),

                // Movement buttons - using shared FocuserControls widget
                const FocuserControls(
                  compact: true,
                  showAutofocus: false,
                ),
                const SizedBox(height: 12),

                // Step size selector
                Row(
                  children: [
                    Text('Step Size:',
                        style: SkotiqTypography.caption
                            .copyWith(color: widget.colors.textSecondary)),
                    const SizedBox(width: 8),
                    // A Wrap, not a horizontal scroll view: at the side
                    // panel's 216px the strip clipped 500 to "50(" with no
                    // fade or arrow to say it continued, so the largest step
                    // read as a rendering fault rather than a control.
                    Expanded(
                      child: Wrap(
                        spacing: _stepChipGap,
                        runSpacing: _stepChipGap,
                        children: [10, 50, 100, 500].map((step) {
                          final isSelected = focusSettings.stepSize == step;
                          return GestureDetector(
                            onTap: () => ref
                                .read(focusSettingsProvider.notifier)
                                .update(focusSettings.copyWith(stepSize: step)),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: isSelected
                                  ? SkotiqDecorations.selectedSurface(
                                      widget.colors.primary,
                                      borderRadius: BorderRadius.circular(
                                          SkotiqTokens.radiusInline4),
                                      fillAlpha: 0.15,
                                    )
                                  : BoxDecoration(
                                      color: widget.colors.background,
                                      borderRadius: BorderRadius.circular(
                                          SkotiqTokens.radiusInline4),
                                      border: Border.all(
                                        color: widget.colors.border,
                                      ),
                                    ),
                              child: Text(
                                '$step',
                                style: SkotiqTypography.caption.copyWith(
                                    fontWeight: isSelected
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                    color: isSelected
                                        ? widget.colors.primary
                                        : widget.colors.textSecondary),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // Go to position button
                SizedBox(
                  width: double.infinity,
                  child: SmallButton(
                    label: 'Go To Position...',
                    icon: SkotiqIcons.move,
                    colors: widget.colors,
                    isEnabled: isConnected &&
                        focuserState.isAbsolute &&
                        !isMoving &&
                        !autofocusRunning,
                    onTap: _showGoToPositionDialog,
                  ),
                ),
                if (isConnected && !focuserState.isAbsolute)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Absolute positioning is not supported by this focuser.',
                      style: SkotiqTypography.caption
                          .copyWith(color: widget.colors.textMuted),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Autofocus Section
          PanelSection(
            title: 'Autofocus',
            colors: widget.colors,
            child: Column(
              children: [
                // Curve fit is the control that actually decides how the sweep
                // is solved, and it is owned by the persisted autofocus
                // settings: `_runAutofocus` always resolves the fit from
                // `AppSettings.afCurveFitting` (see autofocus_controls.dart),
                // and the FFI backend maps THAT value — not the Dart `method`
                // field — onto the native curve enum.
                //
                // `focusSettings.method` is the star METRIC, seeded from
                // `afMethod`, whose only legal value is 'Star HFR'; binding
                // this row to it would render blank and change nothing about
                // the run. Bound to the real setting, with the same vocabulary
                // the Settings screen uses, and edits are written through so
                // the choice survives a restart.
                DropdownRow(
                  label: 'Curve fit',
                  value: curveFitting,
                  items: AutofocusSettings.curveFittingOptions,
                  colors: widget.colors,
                  onChanged: curveFitting == null || autofocusRunning
                      ? null
                      : (value) {
                          if (value == null) return;
                          unawaited(
                            ref
                                .read(appSettingsProvider.notifier)
                                .setAfCurveFitting(value),
                          );
                        },
                ),
                if (curveFitting == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Autofocus settings are still loading.',
                      style: SkotiqTypography.caption
                          .copyWith(color: widget.colors.textMuted),
                    ),
                  ),
                const SizedBox(height: 12),
                InputRowEditable(
                  label: 'Step size',
                  value: '${focusSettings.afStepSize}',
                  suffix: 'steps',
                  colors: widget.colors,
                  onChanged: (value) {
                    final parsed = int.tryParse(value);
                    if (parsed != null && parsed > 0) {
                      ref
                          .read(focusSettingsProvider.notifier)
                          .update(focusSettings.copyWith(afStepSize: parsed));
                    }
                  },
                ),
                const SizedBox(height: 12),
                InputRowEditable(
                  label: 'Steps out',
                  value: '${focusSettings.stepsOut}',
                  colors: widget.colors,
                  onChanged: (value) {
                    final parsed = int.tryParse(value);
                    if (parsed != null && parsed > 0) {
                      ref
                          .read(focusSettingsProvider.notifier)
                          .update(focusSettings.copyWith(stepsOut: parsed));
                    }
                  },
                ),
                const SizedBox(height: 12),
                InputRowEditable(
                  label: 'Exposure',
                  value: focusSettings.exposureTime.toStringAsFixed(1),
                  suffix: 'sec',
                  colors: widget.colors,
                  onChanged: (value) {
                    final parsed = double.tryParse(value);
                    if (parsed != null && parsed > 0) {
                      ref
                          .read(focusSettingsProvider.notifier)
                          .update(focusSettings.copyWith(exposureTime: parsed));
                    }
                  },
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: SmallButton(
                    label: autofocusRunning ? 'Running...' : 'Run Autofocus',
                    icon: autofocusRunning
                        ? SkotiqIcons.loading
                        : SkotiqIcons.focuser,
                    colors: widget.colors,
                    isEnabled: isConnected &&
                        cameraConnected &&
                        !isMoving &&
                        !autofocusRunning &&
                        !_isOfferingCalibration,
                    onTap: _runAutofocus,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // The temperature-compensation model those autofocus runs are
          // building. This tab had no surface for it at all: the only mounted
          // view of the model was the mobile Devices tab, and Settings' focus
          // model page is remote-only, so an operator running autofocus on
          // this very screen could never see the slope/R² their runs produced.
          // FocusModelCurveCard is backend-aware (focusProfileDataProvider), so
          // it is honest here both on the rig and on a paired companion.
          //
          // Deliberately not wrapped in PanelSection: the card draws its own
          // surface + border, and PanelSection would nest a second one.
          Text(
            'Temperature Compensation',
            style: SkotiqTypography.caption.copyWith(
                fontWeight: FontWeight.w600, color: widget.colors.textPrimary),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          const FocusModelCurveCard(),
        ],
      ),
    );
  }
}

/// Modal for sending the focuser to an absolute position.
///
/// Owns its own [TextEditingController] and in-flight state so the move can be
/// awaited without losing the typed value. Cancellation is truthful:
///  * before the move is submitted, Cancel simply backs out and never touches
///    the focuser;
///  * once a move is in flight the only way out is to actually stop the
///    hardware — the action row swaps Cancel for a Stop button that awaits
///    [onHalt], and back/Escape/barrier dismissal is routed to the same halt
///    rather than silently abandoning a driving focuser;
///  * a failure of either the move or the halt keeps the dialog open with an
///    inline, retryable error, and the route is dismissed only after the move
///    succeeds or the halt actually completes.
class GoToPositionDialog extends StatefulWidget {
  /// Value the field starts on — usually the focuser's current position.
  final int initialPosition;

  /// Upper travel limit, or null when the driver hasn't reported one. A
  /// non-positive value from a broken/unknown driver is treated the same as
  /// null. When the
  /// max is unknown the dialog validates only the lower bound instead of
  /// inventing a ceiling.
  final int? maxPosition;

  /// Performs the move. Resolves on success; throwing keeps the dialog open.
  final Future<void> Function(int position) onSubmit;

  /// Halts the focuser. Awaited when the user aborts an in-flight move so the
  /// dialog never closes while the hardware is still driving; throwing keeps
  /// the dialog open with a retryable error.
  final Future<void> Function() onHalt;

  const GoToPositionDialog({
    super.key,
    required this.initialPosition,
    required this.maxPosition,
    required this.onSubmit,
    required this.onHalt,
  });

  @override
  State<GoToPositionDialog> createState() => _GoToPositionDialogState();
}

class _GoToPositionDialogState extends State<GoToPositionDialog> {
  late final TextEditingController _controller;
  bool _submitting = false;
  bool _halting = false;
  bool _dismissed = false;
  String? _errorText;
  String? _haltError;

  /// True while either the move or the halt is still resolving. Both the pop
  /// guard and the control layout key off this so nothing dismisses or
  /// re-submits mid-command.
  bool get _inFlight => _submitting || _halting;

  /// A real, positive ceiling actually reported by the driver, or null.
  int? get _knownMax {
    final max = widget.maxPosition;
    return (max != null && max > 0) ? max : null;
  }

  @override
  void initState() {
    super.initState();
    _controller =
        TextEditingController(text: widget.initialPosition.toString());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _rangeHint =>
      _knownMax != null ? '0 - $_knownMax' : '0 or greater';

  /// Pops the route at most once. The move and halt futures can resolve in
  /// either order (or after the widget is gone); this guard keeps them from
  /// double-popping or popping after dispose.
  void _dismiss() {
    if (_dismissed || !mounted) return;
    _dismissed = true;
    Navigator.of(context).pop();
  }

  Future<void> _submit() async {
    // Guard against a second submit while a command is already in flight.
    if (_inFlight) return;

    final position = int.tryParse(_controller.text.trim());
    if (position == null) {
      setState(() => _errorText = 'Enter a whole number.');
      return;
    }
    if (position < 0) {
      setState(() => _errorText = 'Position must be 0 or greater.');
      return;
    }
    final max = _knownMax;
    if (max != null && position > max) {
      setState(() => _errorText = 'Position must be between 0 and $max.');
      return;
    }

    setState(() {
      _submitting = true;
      _errorText = null;
    });

    try {
      await widget.onSubmit(position);
      if (!mounted) return;
      // If the user asked to stop mid-move, let the halt path own dismissal so
      // the two futures never both pop.
      if (_halting) {
        setState(() => _submitting = false);
        return;
      }
      _dismiss();
    } catch (e) {
      if (!mounted) return;
      // Keep the dialog and the typed value so the user can retry. A halt in
      // flight owns the visible error, so don't clobber it here.
      setState(() {
        _submitting = false;
        if (!_halting) _errorText = 'Move failed: $e';
      });
    }
  }

  /// Awaits a real hardware halt, then dismisses. Kept separate from the
  /// pre-move Cancel so an ordinary back-out never issues a stop command.
  Future<void> _halt() async {
    // Duplicate-guard so repeated Stop taps (or barrier gestures) issue a
    // single halt.
    if (_halting) return;
    setState(() {
      _halting = true;
      _haltError = null;
    });

    try {
      await widget.onHalt();
      if (!mounted) return;
      _dismiss();
    } catch (e) {
      if (!mounted) return;
      // Stop failed — stay open with a retryable error rather than closing on
      // a focuser that may still be moving.
      setState(() {
        _halting = false;
        _haltError = 'Stop failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // While a command is in flight the route must not be abandoned silently;
      // back/Escape/barrier are intercepted below and turned into a real halt.
      canPop: !_inFlight,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // A move is running and the OS/back/barrier tried to close us. Don't
        // walk away from a driving focuser — convert the gesture into a real
        // halt, which dismisses only once the hardware actually stops.
        if (_submitting && !_halting) _halt();
      },
      child: AlertDialog(
        title: const Text('Go To Position'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkotiqTextField(
              label: 'Position',
              hint: _rangeHint,
              controller: _controller,
              keyboardType: TextInputType.number,
              enabled: !_inFlight,
              errorText: _errorText,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
            ),
            if (_haltError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _haltError!,
                  style: SkotiqTypography.caption
                      .copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
        actions: [
          if (!_inFlight)
            SkotiqButton(
              // Pre-move backout: no hardware command, just leave.
              onPressed: () => Navigator.of(context).pop(),
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
            )
          else
            SkotiqButton(
              // Truthful abort: awaits the real halt before closing, with its
              // own busy state and duplicate guard.
              onPressed: _halting ? null : _halt,
              isLoading: _halting,
              label: _halting ? 'Stopping...' : 'Stop',
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
            ),
          SkotiqButton(
            onPressed: _inFlight ? null : _submit,
            isLoading: _submitting,
            label: _submitting ? 'Moving...' : 'Go',
            variant: ButtonVariant.primary,
            size: ButtonSize.small,
          ),
        ],
      ),
    );
  }
}
