import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../services/mount_command_service.dart';
import '../services/slew_and_center.dart';
import '../utils/snackbar_helper.dart';

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

  final bool isEnabled;

  final ButtonVariant variant;

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
    _backendSubscription = ref.listenManual<SkotiqBackend>(backendProvider, (
      previous,
      next,
    ) {
      if (previous == null || identical(previous, next)) return;
      _operationRevision++;
      if (mounted && _operationInFlight) {
        setState(() => _operationInFlight = false);
      }
    });
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

    final showRotateOption = hasRotator && widget.targetRotation != null;
    // Centering solves frames; without a solver the button offers what it
    // can do (a plain slew) and the centering entries say why they are off.
    final solverMissing = ref.watch(plateSolverReadyProvider) == false;
    final mainMode = solverMissing ? SlewMode.slew : widget.defaultMode;

    final slew = ref.watch(mountSlewProgressProvider);
    final visibleLabel = _operationInFlight
        ? slew == null
            ? 'Working...'
            : 'Slewing · ${formatSlewDistance(slew.remainingDegrees)}'
        : widget.label ??
            switch (mainMode) {
              SlewMode.slew => 'Slew',
              SlewMode.slewAndCenter => 'Slew & center',
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
            onPressed: enabled ? () => _handleSlewMode(mainMode) : null,
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
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
            ),
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
              _centeringItem(
                colors,
                mode: SlewMode.slewAndCenter,
                icon: LucideIcons.target,
                label: 'Slew & center',
                solverMissing: solverMissing,
              ),
              if (showRotateOption)
                _centeringItem(
                  colors,
                  mode: SlewMode.slewCenterRotate,
                  icon: LucideIcons.rotateCw,
                  label: 'Slew, Center & Rotate',
                  solverMissing: solverMissing,
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

  PopupMenuItem<SlewMode> _centeringItem(
    SkotiqColors colors, {
    required SlewMode mode,
    required IconData icon,
    required String label,
    required bool solverMissing,
  }) {
    final ink = solverMissing ? colors.textMuted : colors.textPrimary;
    return PopupMenuItem<SlewMode>(
      value: mode,
      enabled: !solverMissing,
      child: Row(
        children: [
          Icon(icon, size: 16, color: ink),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: TextStyle(color: ink)),
                if (solverMissing)
                  Text(
                    'Needs a plate solver',
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSlewMode(SlewMode mode) async {
    if (_operationInFlight) return;
    final revision = ++_operationRevision;
    final backend = ref.read(backendProvider);

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

  Future<void> _handleSlew(int revision, SkotiqBackend backend) async {
    final mountService = ref.read(mountCommandServiceProvider);
    final result = await mountService.slewTo(
      widget.ra,
      widget.dec,
      targetName: widget.targetName,
    );
    if (!mounted ||
        !_isCurrentOperation(revision, backend) ||
        !identical(ref.read(mountCommandServiceProvider), mountService)) {
      return;
    }
    context.showCommandActionResult(result);
  }

  /// The press is still this button's: the same host, and the mount
  /// service the press started with.
  bool Function() _currentFor(int revision, SkotiqBackend backend) {
    final mountService = ref.read(mountCommandServiceProvider);
    return () =>
        _isCurrentOperation(revision, backend) &&
        identical(ref.read(mountCommandServiceProvider), mountService);
  }

  // The button is busy for the run, not for the dialog: after an abort or a
  // failure it has to offer the slew again, not sit on "Working..." behind a
  // finished result.
  Future<void> _handleSlewAndCenter(int revision, SkotiqBackend backend) =>
      slewAndCenter(
        ref,
        context,
        ra: widget.ra,
        dec: widget.dec,
        targetName: widget.targetName,
        dialogTitle: widget.targetName ?? 'Target',
        isCurrent: _currentFor(revision, backend),
      );

  Future<void> _handleSlewCenterRotate(
    int revision,
    SkotiqBackend backend,
  ) =>
      slewCenterAndRotate(
        ref,
        context,
        ra: widget.ra,
        dec: widget.dec,
        targetName: widget.targetName,
        dialogTitle: widget.targetName ?? 'Target',
        isCurrent: _currentFor(revision, backend),
        rotation: () => widget.targetRotation,
        rotationSkipped: (failed) =>
            'Centering failed: ${failed.errorMessage ?? 'Unknown centering error'} '
            'Rotation was skipped.',
      );

  bool _isCurrentOperation(int revision, SkotiqBackend backend) =>
      mounted &&
      revision == _operationRevision &&
      ref.backendScopeOver(backend).isCurrent;
}
