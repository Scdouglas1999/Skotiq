import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../services/mount_command_service.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/focuser_backlash/focuser_backlash_offer.dart';
import '../../imaging/centering_dialog.dart';
import 'glass_card.dart';

/// Quick Actions card with responsive layout.
///
/// Adapts to available width:
/// - Narrow (<280px): Single column stack
/// - Medium (280-400px): 2x2 grid
/// - Wide (>400px): Single row with all 4 buttons
class QuickActionsCard extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const QuickActionsCard({super.key, required this.colors});

  @override
  ConsumerState<QuickActionsCard> createState() => _QuickActionsCardState();
}

enum _QuickActionOperation { snapshot, autofocus, park }

class _QuickActionsCardState extends ConsumerState<QuickActionsCard> {
  _QuickActionOperation? _activeOperation;
  int _operationGeneration = 0;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        _operationGeneration++;
        if (_activeOperation == _QuickActionOperation.snapshot) {
          final notifier = ref.read(sessionStateProvider.notifier);
          if (notifier.mounted) notifier.setCapturing(false);
        }
        if (mounted && _activeOperation != null) {
          setState(() => _activeOperation = null);
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
    final colors = widget.colors;
    // Watch mount capabilities to gate Park button
    final cameraState = ref.watch(cameraStateProvider);
    final focuserState = ref.watch(focuserStateProvider);
    final mountState = ref.watch(mountStateProvider);
    final session = ref.watch(sessionStateProvider);
    final isCameraConnected =
        cameraState.connectionState == DeviceConnectionState.connected;
    final isFocuserConnected =
        focuserState.connectionState == DeviceConnectionState.connected;
    final isMountConnected =
        mountState.connectionState == DeviceConnectionState.connected;
    final hasTarget = session.targetRa != null && session.targetDec != null;
    final actionInFlight = _activeOperation != null;

    // Build action buttons with their callbacks
    final actionButtons = [
      _ActionButtonData(
        icon: LucideIcons.camera,
        label: _activeOperation == _QuickActionOperation.snapshot
            ? 'Capturing...'
            : 'Snapshot',
        onTap: isCameraConnected && !actionInFlight ? _handleSnapshot : null,
      ),
      _ActionButtonData(
        icon: LucideIcons.focus,
        label: _activeOperation == _QuickActionOperation.autofocus
            ? 'Focusing...'
            : 'Autofocus',
        onTap: isCameraConnected && isFocuserConnected && !actionInFlight
            ? _handleAutofocus
            : null,
      ),
      _ActionButtonData(
        icon: LucideIcons.crosshair,
        label: 'Center',
        onTap: isCameraConnected &&
                isMountConnected &&
                hasTarget &&
                !actionInFlight
            ? _handleCenter
            : null,
      ),
      _ActionButtonData(
        icon: LucideIcons.parkingCircle,
        label: _activeOperation == _QuickActionOperation.park
            ? 'Parking...'
            : 'Park',
        onTap: isMountConnected && !actionInFlight
            ? () => _handlePark(mountState)
            : null,
      ),
    ];

    return DashboardGlassCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashboardCardHeader(
            colors: colors,
            icon: LucideIcons.zap,
            title: 'Quick actions',
            accent: colors.primary,
          ),

          const SizedBox(height: DashboardCardStyle.headerGap),

          // Responsive button layout
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;

              if (width < 280) {
                // Narrow: Single column stack
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < actionButtons.length; i++) ...[
                      _ActionButton(
                        icon: actionButtons[i].icon,
                        label: actionButtons[i].label,
                        colors: colors,
                        onTap: actionButtons[i].onTap,
                      ),
                      if (i < actionButtons.length - 1)
                        const SizedBox(height: 8),
                    ],
                  ],
                );
              } else if (width < 400) {
                // Medium: 2x2 grid
                return Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            icon: actionButtons[0].icon,
                            label: actionButtons[0].label,
                            colors: colors,
                            onTap: actionButtons[0].onTap,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _ActionButton(
                            icon: actionButtons[1].icon,
                            label: actionButtons[1].label,
                            colors: colors,
                            onTap: actionButtons[1].onTap,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _ActionButton(
                            icon: actionButtons[2].icon,
                            label: actionButtons[2].label,
                            colors: colors,
                            onTap: actionButtons[2].onTap,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _ActionButton(
                            icon: actionButtons[3].icon,
                            label: actionButtons[3].label,
                            colors: colors,
                            onTap: actionButtons[3].onTap,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              } else {
                // Wide: Single row with all buttons
                return Row(
                  children: [
                    for (var i = 0; i < actionButtons.length; i++) ...[
                      Expanded(
                        child: _ActionButton(
                          icon: actionButtons[i].icon,
                          label: actionButtons[i].label,
                          colors: colors,
                          onTap: actionButtons[i].onTap,
                        ),
                      ),
                      if (i < actionButtons.length - 1)
                        const SizedBox(width: 8),
                    ],
                  ],
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Future<void> _handleSnapshot() async {
    if (!_beginOperation(_QuickActionOperation.snapshot)) return;
    final cameraState = ref.read(cameraStateProvider);
    if (cameraState.connectionState != DeviceConnectionState.connected) {
      context.showErrorSnackBar('Camera not connected');
      _finishOperation(_operationGeneration);
      return;
    }

    final generation = _operationGeneration;
    final container = ProviderScope.containerOf(context, listen: false);
    final backend = ref.read(backendProvider);
    final imagingService = ref.read(imagingServiceProvider);
    final sessionNotifier = ref.read(sessionStateProvider.notifier);
    try {
      var settings = ref.read(exposureSettingsProvider);
      if (cameraState.gain != null) {
        settings = settings.copyWith(gain: cameraState.gain);
      }
      if (cameraState.offset != null) {
        settings = settings.copyWith(offset: cameraState.offset);
      }
      if (cameraState.binning != null) {
        final binParts = cameraState.binning!.split('x');
        if (binParts.length == 2) {
          final bx = int.tryParse(binParts[0]);
          final by = int.tryParse(binParts[1]);
          if (bx != null && by != null) {
            settings = settings.copyWith(binningX: bx, binningY: by);
          }
        }
      }

      sessionNotifier.setCapturing(true);

      final result = await imagingService.captureImage(
        settings: settings,
        targetName: ref.read(sessionStateProvider).targetName,
      );

      if (result != null &&
          _hasAuthority(
            container: container,
            backend: backend,
            generation: generation,
            imagingService: imagingService,
          )) {
        // ImagingService owns preview/stat publication. Re-publishing its
        // early return here can overwrite a newer raw-ready preview.
        sessionNotifier.recordExposureComplete(
          exposureTime: settings.exposureTime,
          hfr: result.stats.hfr,
        );

        if (mounted) context.showSuccessSnackBar('Snapshot captured');
      }
    } catch (e) {
      if (mounted &&
          _hasAuthority(
            container: container,
            backend: backend,
            generation: generation,
            imagingService: imagingService,
          )) {
        context.showErrorSnackBar('Snapshot failed: $e');
      }
    } finally {
      if (_hasAuthority(
        container: container,
        backend: backend,
        generation: generation,
        imagingService: imagingService,
      )) {
        if (sessionNotifier.mounted) sessionNotifier.setCapturing(false);
        _finishOperation(generation);
      }
    }
  }

  Future<void> _handleAutofocus() async {
    if (!_beginOperation(_QuickActionOperation.autofocus)) return;
    final cameraState = ref.read(cameraStateProvider);
    final focuserState = ref.read(focuserStateProvider);

    if (cameraState.connectionState != DeviceConnectionState.connected) {
      context.showErrorSnackBar('Camera not connected');
      _finishOperation(_operationGeneration);
      return;
    }

    if (focuserState.connectionState != DeviceConnectionState.connected) {
      context.showErrorSnackBar('Focuser not connected');
      _finishOperation(_operationGeneration);
      return;
    }

    // Every autofocus launch in the app routes through the one backlash offer
    // (`focuser_backlash_offer.dart`). Placed after the connection checks so
    // nothing is offered for a run that could not have started, and before the
    // authority capture below so the offer's own awaits are not mistaken for
    // the run's. Declining returns here immediately.
    await offerBacklashCalibrationIfDue(context, ref);
    if (!mounted) return;

    final generation = _operationGeneration;
    final container = ProviderScope.containerOf(context, listen: false);
    final backend = ref.read(backendProvider);
    final deviceService = ref.read(deviceServiceProvider);

    // Show progress notification - the device service will handle detailed progress
    // via activeOperationsProvider, but we show a quick snackbar for immediate feedback
    context.showInfoSnackBar(
      'Starting autofocus...',
      duration: const Duration(seconds: 2),
    );

    try {
      final result = await deviceService.runAutofocus(
        exposureTime: 3.0,
        stepSize: 100,
        stepsOut: 7,
        method: 'VCurve',
        binning: 1,
        useSettingsDefaults: true,
      );

      if (!mounted ||
          !_hasAuthority(
            container: container,
            backend: backend,
            generation: generation,
            deviceService: deviceService,
          )) {
        return;
      }

      // Show success with key result metrics
      final hfrText = result.bestHfr.toStringAsFixed(2);
      final posText = result.bestPosition.toString();
      context.showSuccessSnackBar(
        'Autofocus complete: Position $posText, HFR $hfrText',
      );
    } on AutofocusCancelledException {
      if (mounted &&
          _hasAuthority(
            container: container,
            backend: backend,
            generation: generation,
            deviceService: deviceService,
          )) {
        context.showInfoSnackBar('Autofocus cancelled');
      }
    } catch (e) {
      if (mounted &&
          _hasAuthority(
            container: container,
            backend: backend,
            generation: generation,
            deviceService: deviceService,
          )) {
        context.showErrorSnackBar('Autofocus failed: $e');
      }
    } finally {
      if (_hasAuthority(
        container: container,
        backend: backend,
        generation: generation,
        deviceService: deviceService,
      )) {
        _finishOperation(generation);
      }
    }
  }

  Future<void> _handlePark(MountState mountState) async {
    if (!_beginOperation(_QuickActionOperation.park)) return;
    final generation = _operationGeneration;
    final container = ProviderScope.containerOf(context, listen: false);
    final backend = ref.read(backendProvider);
    final service = ref.read(mountCommandServiceProvider);

    try {
      if (!mountState.canPark) {
        context.showErrorSnackBar('Mount driver does not support parking');
        return;
      }
      final result = await service.park();
      if (mounted &&
          _hasAuthority(
            container: container,
            backend: backend,
            generation: generation,
          )) {
        context.showCommandActionResult(result);
      }
    } catch (e) {
      if (mounted &&
          _hasAuthority(
            container: container,
            backend: backend,
            generation: generation,
          )) {
        context.showErrorSnackBar('Failed to park mount: $e');
      }
    } finally {
      if (_hasAuthority(
        container: container,
        backend: backend,
        generation: generation,
      )) {
        _finishOperation(generation);
      }
    }
  }

  void _handleCenter() {
    // Check if we have a target set
    final session = ref.read(sessionStateProvider);
    final targetRa = session.targetRa;
    final targetDec = session.targetDec;

    if (targetRa == null || targetDec == null) {
      context.showWarningSnackBar(
        'No target set. Please set a target first.',
        duration: const Duration(seconds: 3),
      );
      return;
    }

    // Show centering dialog
    if (context.mounted) {
      showCenteringDialog(
        context: context,
        targetRa: targetRa,
        targetDec: targetDec,
        targetName: session.targetName ?? 'Target',
      );
    }
  }

  bool _beginOperation(_QuickActionOperation operation) {
    if (_activeOperation != null) return false;
    _operationGeneration++;
    setState(() => _activeOperation = operation);
    return true;
  }

  void _finishOperation(int generation) {
    if (!mounted || generation != _operationGeneration) return;
    setState(() => _activeOperation = null);
  }

  bool _hasAuthority({
    required ProviderContainer container,
    required SkotiqBackend backend,
    required int generation,
    ImagingService? imagingService,
    DeviceService? deviceService,
  }) {
    if (generation != _operationGeneration ||
        !identical(container.read(backendProvider), backend)) {
      return false;
    }
    if (imagingService != null &&
        !identical(container.read(imagingServiceProvider), imagingService)) {
      return false;
    }
    return deviceService == null ||
        identical(container.read(deviceServiceProvider), deviceService);
  }
}

/// Data class for action button configuration.
class _ActionButtonData {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _ActionButtonData({
    required this.icon,
    required this.label,
    this.onTap,
  });
}

class _ActionButton extends StatefulWidget {
  final IconData icon;
  final String label;
  final SkotiqColors colors;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.colors,
    this.onTap,
  });

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isEnabled = widget.onTap != null;
    final isActiveHover = _isHovered && isEnabled;

    return MouseRegion(
      cursor:
          isEnabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
      onEnter: (_) {
        if (isEnabled) {
          setState(() => _isHovered = true);
        }
      },
      onExit: (_) {
        if (_isHovered) {
          setState(() => _isHovered = false);
        }
      },
      // FocusRing surfaces keyboard focus on these GestureDetector-based
      // action buttons; without it keyboard nav silently skipped them.
      child: FocusRing(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        child: GestureDetector(
          onTap: isEnabled ? widget.onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: isActiveHover
                  ? widget.colors.primary.withValues(alpha: 0.1)
                  : widget.colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              border: Border.all(
                color: isActiveHover
                    ? widget.colors.primary
                    : widget.colors.border,
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  widget.icon,
                  size: 16,
                  color: isEnabled
                      ? (isActiveHover
                          ? widget.colors.primary
                          : widget.colors.textSecondary)
                      : widget.colors.textMuted,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.labelSm.copyWith(
                      color: isEnabled
                          ? (isActiveHover
                              ? widget.colors.primary
                              : widget.colors.textSecondary)
                          : widget.colors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
