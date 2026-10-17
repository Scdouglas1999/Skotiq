import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../services/mount_command_service.dart';
import '../screens/imaging/centering_dialog.dart';
import '../utils/authority_bound_dialog.dart';
import '../utils/confirm_dialog.dart';
import '../utils/snackbar_helper.dart';

/// The slew mode selection for the dropdown.
enum SlewMode {
  /// Basic slew to coordinates.
  slew,

  /// Slew followed by iterative plate-solve centering.
  slewAndCenter,

  /// Slew, center, then rotate to target angle.
  slewCenterRotate,
}

/// A dropdown button for slew operations with three options:
/// - Slew (basic slew to coordinates)
/// - Slew & Center (slew + plate solve centering loop)
/// - Slew, Center & Rotate (slew + center + rotate to target angle)
///
/// The "Slew, Center & Rotate" option is only shown if a rotator is connected
/// AND a [targetRotation] is provided.
class SlewDropdownButton extends ConsumerStatefulWidget {
  /// Right Ascension in hours.
  final double ra;

  /// Declination in degrees.
  final double dec;

  /// Optional target name for display in centering dialog.
  final String? targetName;

  /// Target rotation angle in degrees.
  /// If null, the "Slew, Center & Rotate" option is hidden.
  final double? targetRotation;

  /// Whether the button is enabled.
  final bool isEnabled;

  /// Button variant for styling.
  final ButtonVariant variant;

  /// Optional icon to display.
  final IconData? icon;

  /// Mode executed by the main button.
  final SlewMode defaultMode;

  /// Optional custom label. Defaults to the selected mode’s label.
  final String? label;

  const SlewDropdownButton({
    super.key,
    required this.ra,
    required this.dec,
    this.targetName,
    this.targetRotation,
    this.isEnabled = true,
    this.variant = ButtonVariant.primary,
    this.icon,
    this.label,
    this.defaultMode = SlewMode.slew,
  });

  @override
  ConsumerState<SlewDropdownButton> createState() => _SlewDropdownButtonState();
}

class _SlewDropdownButtonState extends ConsumerState<SlewDropdownButton> {
  bool _operationInFlight = false;
  int _operationRevision = 0;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        _operationRevision++;
        if (mounted && _operationInFlight) {
          setState(() => _operationInFlight = false);
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
    final rotatorState = ref.watch(rotatorStateProvider);
    final hasRotator =
        rotatorState.connectionState == DeviceConnectionState.connected;
    final mountState = ref.watch(mountStateProvider);
    final isMountConnected =
        mountState.connectionState == DeviceConnectionState.connected;
    final enabled = widget.isEnabled && isMountConnected && !_operationInFlight;

    // Determine if slew+center+rotate option should be shown
    final showRotateOption = hasRotator && widget.targetRotation != null;

    final visibleLabel = _operationInFlight
        ? 'Working...'
        : widget.label ??
            switch (widget.defaultMode) {
              SlewMode.slew => 'Slew',
              SlewMode.slewAndCenter => 'Slew & Center',
              SlewMode.slewCenterRotate => 'Slew, Center & Rotate',
            };

    // The filled half runs the default action; the chevron opens alternatives.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Expanded(
          // Carries its own name/role/state: SkotiqButton already publishes
          // Semantics(button, enabled, label) and is keyboard-focusable.
          child: SkotiqButton(
            label: visibleLabel,
            icon: widget.icon ?? LucideIcons.move,
            variant: widget.variant,
            onPressed:
                enabled ? () => _handleSlewMode(widget.defaultMode) : null,
          ),
        ),
        const SizedBox(width: 4),
        // PopupMenuButton publishes no name of its own — its child path is
        // Tooltip('Show menu') > InkWell — so the chevron would reach a screen
        // reader as an unnamed control sitting beside "Slew". Name it for what
        // it opens.
        Semantics(
          button: true,
          enabled: enabled,
          label: 'More slew options',
          child: PopupMenuButton<SlewMode>(
            enabled: enabled,
            onSelected: _handleSlewMode,
            offset: const Offset(0, 40),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg)),
            color: colors.surface,
            tooltip: 'More slew options',
            itemBuilder: (context) => [
              PopupMenuItem<SlewMode>(
                value: SlewMode.slew,
                child: Row(
                  children: [
                    Icon(LucideIcons.move, size: 16, color: colors.textPrimary),
                    const SizedBox(width: 8),
                    Text('Slew', style: TextStyle(color: colors.textPrimary)),
                  ],
                ),
              ),
              PopupMenuItem<SlewMode>(
                value: SlewMode.slewAndCenter,
                child: Row(
                  children: [
                    Icon(LucideIcons.target,
                        size: 16, color: colors.textPrimary),
                    const SizedBox(width: 8),
                    Text('Slew & Center',
                        style: TextStyle(color: colors.textPrimary)),
                  ],
                ),
              ),
              if (showRotateOption)
                PopupMenuItem<SlewMode>(
                  value: SlewMode.slewCenterRotate,
                  child: Row(
                    children: [
                      Icon(LucideIcons.rotateCw,
                          size: 16, color: colors.textPrimary),
                      const SizedBox(width: 8),
                      Text('Slew, Center & Rotate',
                          style: TextStyle(color: colors.textPrimary)),
                    ],
                  ),
                ),
            ],
            // Keep the alternatives menu large enough for touch input.
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: SkotiqTokens.minTouchTarget,
                minHeight: SkotiqTokens.minTouchTarget,
              ),
              child: Icon(
                LucideIcons.chevronDown,
                size: 16,
                color: enabled ? colors.textPrimary : colors.textMuted,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _handleSlewMode(
    SlewMode mode,
  ) async {
    if (_operationInFlight) return;
    final revision = ++_operationRevision;
    final backend = ref.read(backendProvider);

    // The horizon gate runs before anything is dispatched and before the
    // button latches into its working state, so a refused slew leaves the
    // control exactly as it was.
    if (!await _confirmHorizon()) return;
    if (!_isCurrentOperation(revision, backend)) return;

    setState(() => _operationInFlight = true);
    try {
      switch (mode) {
        case SlewMode.slew:
          await _handleSlew(revision, backend);
          break;
        case SlewMode.slewAndCenter:
          await _handleSlewAndCenter(revision, backend);
          break;
        case SlewMode.slewCenterRotate:
          await _handleSlewCenterRotate(revision, backend);
          break;
      }
    } finally {
      if (_isCurrentOperation(revision, backend)) {
        setState(() => _operationInFlight = false);
      }
    }
  }

  Future<void> _handleSlew(
    int revision,
    SkotiqBackend backend,
  ) async {
    final mountService = ref.read(mountCommandServiceProvider);
    final result = await mountService.slewTo(widget.ra, widget.dec);
    if (!mounted ||
        !_isCurrentOperation(revision, backend) ||
        !identical(ref.read(mountCommandServiceProvider), mountService)) {
      return;
    }
    context.showCommandActionResult(result);
  }

  Future<void> _handleSlewAndCenter(
    int revision,
    SkotiqBackend backend,
  ) async {
    if (!await _preflightCentering(revision, backend)) return;

    // First slew to approximate position
    final mountService = ref.read(mountCommandServiceProvider);
    final slewResult = await mountService.slewTo(
      widget.ra,
      widget.dec,
      showFeedback: false,
    );

    if (!mounted ||
        !_isCurrentOperation(revision, backend) ||
        !identical(ref.read(mountCommandServiceProvider), mountService)) {
      return;
    }

    if (!slewResult.isSuccess) {
      context.showCommandActionResult(slewResult);
      return;
    }

    // Wait for slew to complete, then show centering dialog
    // The centering dialog handles the plate solve loop
    if (!mounted) return;
    await showCenteringDialog(
      context: context,
      targetRa: widget.ra,
      targetDec: widget.dec,
      targetName: widget.targetName ?? 'Target',
    );
  }

  Future<void> _handleSlewCenterRotate(
    int revision,
    SkotiqBackend backend,
  ) async {
    if (!await _preflightCentering(revision, backend)) return;

    // First do slew and center
    final mountService = ref.read(mountCommandServiceProvider);
    final slewResult = await mountService.slewTo(
      widget.ra,
      widget.dec,
      showFeedback: false,
    );

    if (!mounted ||
        !_isCurrentOperation(revision, backend) ||
        !identical(ref.read(mountCommandServiceProvider), mountService)) {
      return;
    }

    if (!slewResult.isSuccess) {
      context.showCommandActionResult(slewResult);
      return;
    }

    // Show centering dialog and wait for completion
    CenteringResult? centeringResult;
    if (!mounted) return;
    centeringResult = await showDialog<CenteringResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _CenteringDialogWithResult(
        targetRa: widget.ra,
        targetDec: widget.dec,
        targetName: widget.targetName ?? 'Target',
      ),
    );

    if (!mounted || !_isCurrentOperation(revision, backend)) return;

    // If centering failed or was cancelled, don't rotate
    if (centeringResult == null || !centeringResult.success) {
      if (centeringResult != null) {
        final reason =
            centeringResult.errorMessage ?? 'Unknown centering error';
        context.showWarningSnackBar(
          'Centering failed: $reason Rotation was skipped.',
        );
      }
      return;
    }

    // Now rotate to target angle
    if (widget.targetRotation != null) {
      try {
        final rotatorState = ref.read(rotatorStateProvider);
        if (rotatorState.connectionState == DeviceConnectionState.connected &&
            rotatorState.deviceId != null) {
          final deviceBackend = ref.read(deviceBackendProvider);
          await deviceBackend.rotatorMoveTo(
            rotatorState.deviceId!,
            widget.targetRotation!,
          );
          if (mounted &&
              _isCurrentOperation(revision, backend) &&
              identical(ref.read(deviceBackendProvider), deviceBackend) &&
              ref.read(rotatorStateProvider).deviceId ==
                  rotatorState.deviceId) {
            context.showSuccessSnackBar(
                'Rotating to ${widget.targetRotation!.toStringAsFixed(1)}°');
          }
        }
      } catch (e) {
        if (mounted && _isCurrentOperation(revision, backend)) {
          context.showErrorSnackBar('Rotation failed: $e');
        }
      }
    }
  }

  /// Confirms a below-horizon GoTo before dispatching it.
  ///
  /// No configured site means there is no altitude to judge. A settings-load
  /// failure blocks the command because it cannot be distinguished from a
  /// hidden configured site.
  Future<bool> _confirmHorizon() async {
    try {
      await ref.read(appSettingsProvider.future);
    } catch (error) {
      if (mounted) {
        context.showErrorSnackBar(
          'Unable to verify target altitude because settings could not be '
          'loaded. Slew was not sent.',
        );
      }
      return false;
    }
    if (!mounted) return false;

    // Whether a site exists at all is [appObserverLocationProvider]'s call, not
    // ours — (0, 0) is a real place and only that provider gets to decide it
    // means "unset".
    final site = ref.read(appObserverLocationProvider);
    if (site == null) return true;

    // Same alt/az model the scheduler uses to decide what is worth imaging, so
    // the slew gate and the planner never disagree about where a target is.
    final (altitudeDeg, azimuthDeg) =
        ref.read(schedulerServiceProvider).calculateAltAz(
              raHours: widget.ra,
              decDegrees: widget.dec,
              time: DateTime.now().toUtc(),
              latitudeDegrees: site.latitude,
              longitudeDegrees: site.longitude,
            );

    // Settings → Location → effective horizon. 0° (the mathematical horizon)
    // is the default and the floor: a site cannot opt out of the ground.
    final floorDeg = ref.read(effectiveHorizonDegProvider);
    if (altitudeDeg >= 0 && altitudeDeg >= floorDeg) return true;
    if (!mounted) return false;

    final target = widget.targetName ?? 'That target';
    final where = 'azimuth ${azimuthDeg.toStringAsFixed(0)}°';

    if (altitudeDeg < 0) {
      return ConfirmDialog.show(
        context: context,
        title: 'Target is below the horizon',
        message: '$target is ${(-altitudeDeg).toStringAsFixed(1)}° below the '
            'horizon right now ($where) — it is under the ground. Slewing '
            'there can drive the telescope into the pier, a tripod leg or the '
            'ground. Check the coordinates, and check your site in '
            'Settings → Location.',
        confirmLabel: 'Slew anyway',
        isDestructive: true,
      );
    }

    return ConfirmDialog.show(
      context: context,
      title: 'Target is below your horizon limit',
      message: '$target is only ${altitudeDeg.toStringAsFixed(1)}° above the '
          'horizon ($where), under the ${floorDeg.toStringAsFixed(0)}° '
          'effective horizon set in Settings → Location. It may be behind '
          'trees or a roof, and it will be looking through a lot of air.',
      confirmLabel: 'Slew anyway',
    );
  }

  Future<bool> _preflightCentering(
    int revision,
    SkotiqBackend backend,
  ) async {
    final camera = ref.read(cameraStateProvider);
    if (camera.connectionState != DeviceConnectionState.connected) {
      if (mounted && _isCurrentOperation(revision, backend)) {
        context.showWarningSnackBar(
          'Connect an imaging camera before using Slew & Center.',
        );
      }
      return false;
    }

    final centering = ref.read(centeringServiceProvider);
    if (centering.isRunning) {
      if (mounted && _isCurrentOperation(revision, backend)) {
        context
            .showWarningSnackBar('A centering operation is already running.');
      }
      return false;
    }

    try {
      await ref.read(plateSolveServiceProvider).ensureSolverAvailable();
      return _isCurrentOperation(revision, backend);
    } on SolverNotAvailableError catch (e) {
      if (mounted && _isCurrentOperation(revision, backend)) {
        context.showWarningSnackBar(e.message);
      }
      return false;
    } catch (e) {
      if (mounted && _isCurrentOperation(revision, backend)) {
        context.showErrorSnackBar('Could not check the plate solver: $e');
      }
      return false;
    }
  }

  bool _isCurrentOperation(int revision, SkotiqBackend backend) =>
      mounted &&
      revision == _operationRevision &&
      identical(ref.read(backendProvider), backend);
}

/// Internal version of CenteringDialog that returns the result
class _CenteringDialogWithResult extends ConsumerStatefulWidget {
  final double targetRa;
  final double targetDec;
  final String targetName;

  const _CenteringDialogWithResult({
    required this.targetRa,
    required this.targetDec,
    required this.targetName,
  });

  @override
  ConsumerState<_CenteringDialogWithResult> createState() =>
      _CenteringDialogWithResultState();
}

class _CenteringDialogWithResultState
    extends ConsumerState<_CenteringDialogWithResult> {
  bool _isCentering = false;
  bool _cancelInFlight = false;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  Future<AppSettingsState> _resolvedAppSettings() =>
      ref.read(appSettingsProvider.future);

  CenteringConfig _centeringConfig(AppSettingsState settings) {
    final profile = ref.read(activeEquipmentProfileProvider);
    final exposureTime = profile?.defaultCenteringExposure ?? 5.0;
    return CenteringConfig(
      maxIterations: 5,
      toleranceArcsec: 30.0,
      exposureTime: exposureTime > 0 ? exposureTime : 5.0,
      binning: profile?.defaultBinX ?? 2,
      gain: profile?.defaultGain,
      offset: profile?.defaultOffset,
      // Settings → Plate Solving → "Sync mount when centering". Without the
      // sync each correction re-issues the slew that produced the mis-pointed
      // frame, so the offset never changes and the run ends on max iterations.
      syncMount: settings.centeringSyncMount,
    );
  }

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next) || !mounted) return;
        closeAuthorityBoundDialog(context);
      },
    );
    // Auto-start centering
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startCentering();
    });
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  Future<void> _startCentering() async {
    setState(() {
      _isCentering = true;
    });

    final centeringService = ref.read(centeringServiceProvider);
    late final AppSettingsState appSettings;
    try {
      appSettings = await _resolvedAppSettings();
    } catch (error) {
      if (mounted) {
        setState(() => _isCentering = false);
        Navigator.of(context).pop(
          CenteringResult.failure(
            errorMessage: 'Unable to load plate-solving settings: $error',
            iterations: 0,
            iterationHistory: const [],
          ),
        );
      }
      return;
    }
    if (!mounted) return;

    final solverConfig = PlateSolverConfig(
      type: PlateSolverType.astap,
      executablePath: appSettings.astapPath,
      timeoutSeconds: appSettings.plateSolveTimeout,
      searchRadius: appSettings.plateSolveSearchRadius,
    );

    try {
      final result = await centeringService.centerOnTarget(
        targetRa: widget.targetRa,
        targetDec: widget.targetDec,
        solverConfig: solverConfig,
        config: _centeringConfig(appSettings),
        onStatusUpdate: (status) {
          ref.read(centeringStatusProvider.notifier).state = status;
        },
      );

      if (mounted) {
        setState(() {
          _isCentering = false;
        });

        // Return result when done
        Navigator.of(context).pop(result);
      }
    } on SolverNotAvailableError catch (e) {
      if (mounted) {
        final failureResult = CenteringResult.failure(
          errorMessage: e.message,
          iterations: 0,
          iterationHistory: const [],
        );
        setState(() => _isCentering = false);
        Navigator.of(context).pop(failureResult);
      }
    } catch (e) {
      if (mounted) {
        final failureResult = CenteringResult.failure(
          errorMessage: 'Centering error: $e',
          iterations: 0,
          iterationHistory: [],
        );
        setState(() {
          _isCentering = false;
        });
        Navigator.of(context).pop(failureResult);
      }
    }
  }

  Future<void> _cancelCentering() async {
    setState(() => _cancelInFlight = true);
    try {
      await ref.read(centeringServiceProvider).stop();
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Cancel failed: $e');
      }
    }
    if (mounted) {
      Navigator.of(context).pop(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final centeringStatus = ref.watch(centeringStatusProvider);
    final colors = SkotiqColors.of(context);

    return Dialog(
      child: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 400,
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.target, color: colors.primary, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Centering Target',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: colors.textPrimary,
                          ),
                        ),
                        Text(
                          widget.targetName,
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (_isCentering) ...[
                const SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
                const SizedBox(height: 16),
                Text(
                  centeringStatus.message ?? 'Centering...',
                  style: TextStyle(color: colors.textSecondary),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Iteration ${centeringStatus.currentIteration}/${centeringStatus.maxIterations}',
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.textMuted,
                  ),
                ),
                if (centeringStatus.currentOffsetArcmin != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Offset: ${centeringStatus.currentOffsetArcmin!.toStringAsFixed(2)} arcmin',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 16),
              if (_isCentering)
                SkotiqButton(
                  onPressed: _cancelInFlight ? null : _cancelCentering,
                  label: 'Cancel',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
