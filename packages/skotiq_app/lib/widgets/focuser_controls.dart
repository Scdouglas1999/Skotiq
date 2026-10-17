import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../utils/snackbar_helper.dart';
import 'focuser_backlash/focuser_backlash_offer.dart';

/// Reusable widget for focuser movement controls and autofocus.
///
/// This eliminates duplicate focuser button implementations across screens.
/// Use this widget instead of implementing custom _FocusButton or _MoveButton classes.
class FocuserControls extends ConsumerStatefulWidget {
  /// Whether to use compact sizing for the controls.
  final bool compact;

  /// Whether to show the autofocus button.
  final bool showAutofocus;

  /// Callback invoked when autofocus completes successfully.
  final VoidCallback? onAutofocusComplete;

  const FocuserControls({
    super.key,
    this.compact = false,
    this.showAutofocus = true,
    this.onAutofocusComplete,
  });

  @override
  ConsumerState<FocuserControls> createState() => _FocuserControlsState();
}

class _FocuserControlsState extends ConsumerState<FocuserControls> {
  bool _isRunningAutofocus = false;
  bool _isMoving = false;
  bool _isOfferingCalibration = false;
  ProviderSubscription<DeviceService>? _serviceSubscription;

  @override
  void initState() {
    super.initState();
    _serviceSubscription = ref.listenManual<DeviceService>(
      deviceServiceProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        if (mounted) {
          setState(() {
            _isRunningAutofocus = false;
            _isMoving = false;
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

  FocuserState? get _focuserState => ref.watch(focuserStateProvider);
  bool get _isConnected =>
      _focuserState?.connectionState == DeviceConnectionState.connected;

  Future<void> _moveRelative(int steps) async {
    final service = ref.read(deviceServiceProvider);
    if (_isMoving || service.isAutofocusRunning) return;
    _isMoving = true;
    setState(() {});
    try {
      await service.moveFocuserRelative(steps);
    } catch (e) {
      if (mounted && _isCurrentService(service)) {
        context.showErrorSnackBar('Failed to move focuser: $e');
      }
    } finally {
      if (_isCurrentService(service)) {
        _isMoving = false;
        setState(() {});
      }
    }
  }

  Future<void> _halt() async {
    final service = ref.read(deviceServiceProvider);
    final cancellingAutofocus = service.isAutofocusRunning;
    try {
      if (cancellingAutofocus) {
        await service.cancelAutofocus();
      } else {
        await service.haltFocuser();
      }
    } catch (e) {
      if (mounted && _isCurrentService(service)) {
        context.showErrorSnackBar(
          cancellingAutofocus
              ? 'Failed to cancel autofocus: $e'
              : 'Failed to halt focuser: $e',
        );
      }
    }
  }

  /// The autofocus button, which may stop to offer a backlash measurement
  /// first.
  ///
  /// The offer is not the run: the button keeps its resting label while the
  /// dialog is open, and [_isOfferingCalibration] swallows a second tap rather
  /// than stacking a second offer. Declining proceeds into [_startAutofocus]
  /// immediately — see `focuser_backlash_offer.dart`.
  Future<void> _runAutofocus() async {
    if (_isOfferingCalibration ||
        _isRunningAutofocus ||
        _isMoving ||
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
        widget.onAutofocusComplete?.call();
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
    final colors = SkotiqColors.of(context);
    final focusSettings = ref.watch(focusSettingsProvider);
    final cameraState = ref.watch(cameraStateProvider);
    final sessionState = ref.watch(sessionStateProvider);
    final focuserState = ref.watch(focuserStateProvider);
    final stepSize = focusSettings.stepSize;
    final buttonSize = widget.compact ? 32.0 : 40.0;

    final cameraConnected =
        cameraState.connectionState == DeviceConnectionState.connected;
    final autofocusRunning = sessionState.isAutofocusing || _isRunningAutofocus;
    final focuserMoving = focuserState.isMoving || _isMoving;
    final canMove = _isConnected && !focuserMoving && !autofocusRunning;
    final canHalt = _isConnected && (focuserMoving || autofocusRunning);
    final canAutofocus = _isConnected &&
        cameraConnected &&
        !focuserMoving &&
        !autofocusRunning &&
        !_isOfferingCalibration;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _MoveButton(
              icon: LucideIcons.chevronsLeft,
              size: buttonSize,
              onPressed: canMove ? () => _moveRelative(-stepSize * 10) : null,
            ),
            const SizedBox(width: 4),
            _MoveButton(
              icon: LucideIcons.chevronLeft,
              size: buttonSize,
              onPressed: canMove ? () => _moveRelative(-stepSize) : null,
            ),
            const SizedBox(width: 4),
            _MoveButton(
              icon: LucideIcons.octagon,
              size: buttonSize,
              color: colors.error,
              onPressed: canHalt ? _halt : null,
            ),
            const SizedBox(width: 4),
            _MoveButton(
              icon: LucideIcons.chevronRight,
              size: buttonSize,
              onPressed: canMove ? () => _moveRelative(stepSize) : null,
            ),
            const SizedBox(width: 4),
            _MoveButton(
              icon: LucideIcons.chevronsRight,
              size: buttonSize,
              onPressed: canMove ? () => _moveRelative(stepSize * 10) : null,
            ),
          ],
        ),
        if (widget.showAutofocus) ...[
          const SizedBox(height: 8),
          SkotiqButton(
            label: autofocusRunning ? 'Running...' : 'Run Autofocus',
            icon: autofocusRunning ? LucideIcons.loader2 : LucideIcons.focus,
            size: widget.compact ? ButtonSize.small : ButtonSize.medium,
            onPressed: canAutofocus ? _runAutofocus : null,
          ),
        ],
      ],
    );
  }
}

class _MoveButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback? onPressed;
  final Color? color;

  const _MoveButton({
    required this.icon,
    required this.size,
    this.onPressed,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Material(
      color: colors.surfaceAlt,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
      // The tap lived on a bare gesture wrapper, which publishes an action
      // and no role, so assistive tech read a live control as an inert
      // disabled panel. The flags are only published when given.
      child: Semantics(
          button: true,
          enabled: onPressed != null,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(
                icon,
                size: size * 0.5,
                color: onPressed != null
                    ? (color ?? colors.textPrimary)
                    : colors.textMuted,
              ),
            ),
          )),
    );
  }
}
