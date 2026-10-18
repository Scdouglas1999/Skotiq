import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../utils/snackbar_helper.dart';

/// Widget that displays the current operation progress in a compact status bar format.
///
/// Shows:
/// - Operation type icon
/// - Description / current step
/// - Progress bar (determinate or indeterminate)
/// - Elapsed time
/// - Cancel button (if operation is cancellable)
class OperationStatusBar extends ConsumerStatefulWidget {
  const OperationStatusBar({super.key});

  @override
  ConsumerState<OperationStatusBar> createState() => _OperationStatusBarState();
}

class _OperationStatusBarState extends ConsumerState<OperationStatusBar>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _slideController;
  late Animation<double> _slideAnimation;
  Timer? _elapsedTimer;
  String? _cancellingOperationId;
  // Tracks whether build() decided the timer should be running, so we can
  // restart on resume without depending on operation provider state.
  bool _timerShouldRun = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _slideAnimation = CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOut,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_timerShouldRun &&
          (_elapsedTimer == null || !_elapsedTimer!.isActive)) {
        _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() {});
        });
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _elapsedTimer?.cancel();
      _elapsedTimer = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _slideController.dispose();
    _elapsedTimer?.cancel();
    super.dispose();
  }

  void _startElapsedTimer() {
    _timerShouldRun = true;
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _stopElapsedTimer() {
    _timerShouldRun = false;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
  }

  Future<void> _cancelOperation(OperationProgress operation) async {
    if (_cancellingOperationId == operation.id) return;
    setState(() => _cancellingOperationId = operation.id);

    try {
      switch (operation.type) {
        // A home is mount motion like a slew, and Abort slew is what stops it.
        case OperationType.slewToTarget:
        case OperationType.homeMount:
          await ref.read(deviceServiceProvider).abortMountSlew();
          break;
        case OperationType.autofocus:
          await ref.read(deviceServiceProvider).cancelAutofocus();
          break;
        default:
          throw UnsupportedError(
            '${operation.type.label} cannot be cancelled from the status bar',
          );
      }

      // Do not remove the operation here. Its owning Future clears the exact
      // operation when cancellation has actually propagated. Removing by type
      // here could hide work that is still stopping, or erase a newer operation
      // of the same type that started while the cancel request was in flight.
    } catch (e) {
      if (!mounted) return;
      setState(() => _cancellingOperationId = null);
      context.showErrorSnackBar('Cancel failed: $e');
    }
  }

  IconData _getOperationIcon(OperationType type) {
    switch (type) {
      case OperationType.slewToTarget:
        return LucideIcons.move3d;
      case OperationType.autofocus:
        return LucideIcons.focus;
      case OperationType.filterChange:
        return LucideIcons.circleDot;
      case OperationType.plateSolve:
        return LucideIcons.compass;
      case OperationType.cooling:
        return LucideIcons.thermometerSnowflake;
      case OperationType.warming:
        return LucideIcons.thermometerSun;
      case OperationType.centeringLoop:
        return LucideIcons.crosshair;
      case OperationType.domeSlew:
        return LucideIcons.home;
      case OperationType.parkMount:
        return LucideIcons.parkingCircle;
      case OperationType.unparkMount:
        return LucideIcons.play;
      case OperationType.homeMount:
        return LucideIcons.home;
      case OperationType.dither:
        return LucideIcons.shuffle;
      case OperationType.guideSettle:
        return LucideIcons.target;
      case OperationType.focuserMove:
        return LucideIcons.focus;
      case OperationType.rotatorMove:
        return LucideIcons.rotateCw;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final hasOperation = ref.watch(hasActiveOperationProvider);
    final operation = ref.watch(primaryOperationProvider);

    // Handle animation and timer based on operation presence
    if (hasOperation && operation != null) {
      if (!_slideController.isCompleted) {
        _slideController.forward();
        _startElapsedTimer();
      }
    } else {
      if (_slideController.isCompleted || _slideController.isAnimating) {
        _slideController.reverse();
        _stopElapsedTimer();
      }
    }

    return SizeTransition(
      sizeFactor: _slideAnimation,
      alignment: AlignmentDirectional.topStart,
      child: operation != null
          ? _buildOperationBar(operation, colors)
          : const SizedBox.shrink(),
    );
  }

  Widget _buildOperationBar(OperationProgress operation, SkotiqColors colors) {
    final isCancelling = _cancellingOperationId == operation.id;
    return Container(
      height: 28,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      decoration: SkotiqDecorations.emphasisSurface(
        colors.primary,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 8),
          // Operation icon
          Icon(
            _getOperationIcon(operation.type),
            size: 14,
            color: colors.primary,
          ),
          const SizedBox(width: 8),
          // Description / current step
          Flexible(
            child: Text(
              operation.currentStep ?? operation.description,
              style: TextStyle(
                fontSize: 11,
                color: colors.textPrimary,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          // Progress indicator
          SizedBox(
            width: 80,
            child: operation.progress != null
                ? LinearProgressIndicator(
                    value: operation.progress,
                    backgroundColor: colors.border,
                    valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
                    minHeight: 4,
                  )
                : LinearProgressIndicator(
                    backgroundColor: colors.border,
                    valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
                    minHeight: 4,
                  ),
          ),
          const SizedBox(width: 12),
          // Elapsed time
          Text(
            operation.elapsedFormatted,
            style: TextStyle(
              fontSize: 10,
              color: colors.textMuted,
              fontFamily: 'monospace',
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          // Cancel button (if cancellable)
          if (operation.canCancel) ...[
            const SizedBox(width: 8),
            MouseRegion(
              cursor: isCancelling
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
              // The tap lived on a bare gesture wrapper, which publishes an action
              // and no role, so assistive tech read a live control as an inert
              // disabled panel. The flags are only published when given.
              child: Semantics(
                  button: true,
                  enabled: !isCancelling,
                  label: 'Cancel',
                  child: GestureDetector(
                    onTap:
                        isCancelling ? null : () => _cancelOperation(operation),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: SkotiqDecorations.tintedBadge(
                        colors.error,
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusXs),
                      ),
                      child: isCancelling
                          ? SizedBox(
                              width: 12,
                              height: 12,
                              child:
                                  SkotiqSpinner(size: 12, color: colors.error),
                            )
                          : Icon(
                              LucideIcons.x,
                              size: 12,
                              color: colors.error,
                            ),
                    ),
                  )),
            ),
          ],
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// Inline operation indicator for use within other widgets.
/// Shows a compact spinning indicator with operation name.
class OperationIndicator extends ConsumerWidget {
  final OperationType type;

  const OperationIndicator({super.key, required this.type});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final operation = ref.watch(activeOperationsProvider)[type];

    if (operation == null) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: SkotiqDecorations.tintedBadge(
        colors.primary,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: operation.progress != null
                ? CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
                    value: operation.progress,
                  )
                : SkotiqSpinner(size: 12, color: colors.primary),
          ),
          const SizedBox(width: 6),
          Text(
            operation.currentStep ?? type.activeLabel,
            style: TextStyle(
              fontSize: 11,
              color: colors.primary,
            ),
          ),
        ],
      ),
    );
  }
}
