import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../../utils/snackbar_helper.dart';
import 'panel_widgets.dart';

class RotatorPanel extends ConsumerStatefulWidget {
  final SkotiqColors colors;

  const RotatorPanel({super.key, required this.colors});

  @override
  ConsumerState<RotatorPanel> createState() => _RotatorPanelState();
}

class _RotatorPanelState extends ConsumerState<RotatorPanel> {
  final _angleController = TextEditingController();
  final _angleFocusNode = FocusNode();
  final _syncController = TextEditingController();
  bool _isGoingTo = false;
  bool _isCommandInFlight = false;
  ProviderSubscription<DeviceService>? _serviceSubscription;

  @override
  void initState() {
    super.initState();
    _serviceSubscription = ref.listenManual<DeviceService>(
      deviceServiceProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        if (mounted && (_isGoingTo || _isCommandInFlight)) {
          setState(() {
            _isGoingTo = false;
            _isCommandInFlight = false;
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _serviceSubscription?.close();
    _angleController.dispose();
    _angleFocusNode.dispose();
    _syncController.dispose();
    super.dispose();
  }

  RotatorState get _rotatorState => ref.watch(rotatorStateProvider);
  bool get _isConnected =>
      _rotatorState.connectionState == DeviceConnectionState.connected;
  bool get _isMoving => _rotatorState.isMoving;

  /// Resolves the rotator's valid absolute-angle range from its reported
  /// capabilities, falling back to a full 0..360 turn when the driver does
  /// not advertise bounds. An inverted or degenerate range (min >= max) is
  /// treated as missing data and also falls back to 0..360.
  ({double min, double max}) _angleRange() {
    final caps = ref
        .read(equipmentRotatorCapabilitiesProvider(
          _rotatorState.deviceId ?? '',
        ))
        .valueOrNull;
    final min = caps?.minAngleDeg ?? 0.0;
    final max = caps?.maxAngleDeg ?? 360.0;
    if (!min.isFinite || !max.isFinite || min >= max) {
      return (min: 0.0, max: 360.0);
    }
    return (min: min, max: max);
  }

  Future<void> _moveRelative(double delta) async {
    if (_isMoving || _isCommandInFlight) return;
    final service = ref.read(deviceServiceProvider);
    setState(() => _isCommandInFlight = true);
    try {
      await service.moveRotatorRelative(delta);
    } catch (e) {
      if (mounted && _isCurrentService(service)) {
        context.showErrorSnackBar('Failed to move rotator: $e');
      }
    } finally {
      if (_isCurrentService(service)) {
        setState(() => _isCommandInFlight = false);
      }
    }
  }

  Future<void> _goToAngle() async {
    final range = _angleRange();
    final text = _angleController.text.trim();
    final angle = double.tryParse(text);
    if (angle == null || !angle.isFinite) {
      context.showErrorSnackBar(
        'Enter a valid angle '
        '(${range.min.toStringAsFixed(0)}-${range.max.toStringAsFixed(0)})',
      );
      return;
    }
    if (angle < range.min || angle > range.max) {
      context.showErrorSnackBar(
        'Angle must be between '
        '${range.min.toStringAsFixed(0)} and ${range.max.toStringAsFixed(0)}',
      );
      return;
    }

    if (_isGoingTo || _isCommandInFlight) return;
    final service = ref.read(deviceServiceProvider);
    setState(() {
      _isGoingTo = true;
      _isCommandInFlight = true;
    });
    try {
      await service.moveRotatorTo(angle);
    } catch (e) {
      if (mounted && _isCurrentService(service)) {
        context.showErrorSnackBar('Failed to move rotator: $e');
      }
    } finally {
      if (_isCurrentService(service)) {
        setState(() {
          _isGoingTo = false;
          _isCommandInFlight = false;
        });
      }
    }
  }

  Future<void> _halt() async {
    final service = ref.read(deviceServiceProvider);
    try {
      await service.haltRotator();
    } catch (e) {
      if (mounted && _isCurrentService(service)) {
        context.showErrorSnackBar('Failed to halt rotator: $e');
      }
    }
  }

  /// Sync the rotator's current mechanical position to a known sky position
  /// angle (ASCOM IRotatorV3 Sync). Distinct from Go-To: it sets the
  /// mechanical↔sky offset without moving the rotator.
  Future<void> _syncToPa() async {
    final pa = double.tryParse(_syncController.text);
    if (pa == null || !pa.isFinite || pa < 0 || pa > 360) {
      if (mounted) {
        context.showErrorSnackBar('Enter a sky PA between 0 and 360°');
      }
      return;
    }
    if (_isCommandInFlight || _isMoving) return;
    final service = ref.read(deviceServiceProvider);
    setState(() => _isCommandInFlight = true);
    try {
      await service.syncRotatorToPa(pa);
      if (mounted && _isCurrentService(service)) {
        context.showSuccessSnackBar(
          'Synced rotator to ${pa.toStringAsFixed(1)}° sky PA',
        );
      }
    } catch (e) {
      if (mounted && _isCurrentService(service)) {
        context.showErrorSnackBar('Failed to sync rotator: $e');
      }
    } finally {
      if (_isCurrentService(service)) {
        setState(() => _isCommandInFlight = false);
      }
    }
  }

  bool _isCurrentService(DeviceService service) =>
      mounted && identical(ref.read(deviceServiceProvider), service);

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;

    // Gate absolute-angle move and halt on the rotator's
    // reported capabilities. Hide Go-To entirely when canMoveAbsolute is
    // false — the workflow has no analog form. Halt is shown only while
    // moving anyway, but we drop it when the driver can't halt.
    final rotatorCapsAsync = ref.watch(
        equipmentRotatorCapabilitiesProvider(_rotatorState.deviceId ?? ''));
    final canMoveAbsolute = gateCapability<RotatorCapabilities>(
      rotatorCapsAsync,
      (c) => c.canMoveAbsolute,
    );
    final canHalt = gateCapability<RotatorCapabilities>(
      rotatorCapsAsync,
      (c) => c.canHalt,
    );
    final canSync = gateCapability<RotatorCapabilities>(
      rotatorCapsAsync,
      (c) => c.canSync,
    );

    // Valid absolute-angle range for the Go-To input hint. Mirrors the
    // validation in _goToAngle: use the driver's reported bounds, falling
    // back to a full turn (0..360) when they are absent or degenerate.
    final caps = rotatorCapsAsync.valueOrNull;
    final rawMin = caps?.minAngleDeg ?? 0.0;
    final rawMax = caps?.maxAngleDeg ?? 360.0;
    final hasValidRange = rawMin.isFinite && rawMax.isFinite && rawMin < rawMax;
    final minAngle = hasValidRange ? rawMin : 0.0;
    final maxAngle = hasValidRange ? rawMax : 360.0;

    return ListView(
      // The SidePanel already pads its content by 16 (05 §15).
      padding: EdgeInsets.zero,
      children: [
        // Current angle display
        _buildAngleDisplay(colors),
        const SizedBox(height: 16),

        // Go To section — visible only when the driver supports absolute
        // moves. Relative move falls back to a sequence of small steps so
        // it stays available on any rotator.
        if (canMoveAbsolute) ...[
          PanelSection(
            title: 'Go To Angle',
            colors: colors,
            child: _buildGoToSection(colors, minAngle, maxAngle),
          ),
          const SizedBox(height: 16),
        ],

        // Relative movement section
        PanelSection(
          title: 'Relative move',
          colors: colors,
          child: _buildRelativeMoveSection(colors),
        ),
        const SizedBox(height: 16),

        // Sync section — calibrate the mechanical↔sky offset (IRotatorV3
        // Sync) without moving. Drivers that cannot sync do not get a dead
        // control.
        if (canSync) ...[
          PanelSection(
            title: 'Sync Sky PA',
            colors: colors,
            child: _buildSyncSection(colors, canSync: canSync),
          ),
          const SizedBox(height: 16),
        ],

        // Halt button — only meaningful when the driver supports halt
        // and the rotator is currently moving.
        if (_isMoving && canHalt)
          SizedBox(
            width: double.infinity,
            child: SmallButton(
              label: 'HALT',
              icon: LucideIcons.octagon,
              colors: colors,
              isEnabled: _isConnected,
              onTap: _halt,
            ),
          ),
      ],
    );
  }

  Widget _buildAngleDisplay(SkotiqColors colors) {
    final angle = _rotatorState.position;
    final mechanicalAngle = _rotatorState.mechanicalPosition;

    return SkotiqCard(
      padding: const EdgeInsets.all(16),
      borderRadius: SkotiqTokens.radiusLg,
      child: Column(
        children: [
          // Visual angle indicator
          SizedBox(
            width: 100,
            height: 100,
            child: CustomPaint(
              painter: _AngleIndicatorPainter(
                angle: angle ?? 0,
                primaryColor: colors.primary,
                trackColor: colors.border,
                isConnected: _isConnected,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      // No angle is an em dash, never '---'.
                      angle != null ? '${angle.toStringAsFixed(1)}°' : '\u2014',
                      style: SkotiqTypography.readoutSm.copyWith(
                        color: _isConnected
                            ? colors.textPrimary
                            : colors.textMuted,
                      ),
                    ),
                    if (_isMoving)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          'Moving...',
                          style: SkotiqTypography.caption.copyWith(
                              fontWeight: FontWeight.w500,
                              color: colors.accent),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Mechanical position (if different)
          if (mechanicalAngle != null &&
              angle != null &&
              (mechanicalAngle - angle).abs() > 0.1)
            Text(
              'Mechanical: ${mechanicalAngle.toStringAsFixed(1)}°',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textMuted),
            ),
          if (!_isConnected)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Rotator not connected',
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGoToSection(
    SkotiqColors colors,
    double minAngle,
    double maxAngle,
  ) {
    final canGoTo =
        _isConnected && !_isMoving && !_isGoingTo && !_isCommandInFlight;

    return Row(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
              border: Border.all(color: colors.border),
            ),
            child: TextField(
              controller: _angleController,
              focusNode: _angleFocusNode,
              style: SkotiqTypography.bodySm
                  .copyWith(color: colors.textPrimary),
              decoration: InputDecoration(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: InputBorder.none,
                isDense: true,
                hintText:
                    '${minAngle.toStringAsFixed(1)} - ${maxAngle.toStringAsFixed(1)}',
                hintStyle: SkotiqTypography.caption
                    .copyWith(color: colors.textMuted),
                suffixText: '°',
                suffixStyle: SkotiqTypography.caption
                    .copyWith(color: colors.textMuted),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              enabled: _isConnected && !_isCommandInFlight,
              onSubmitted: (_) {
                if (canGoTo) _goToAngle();
              },
            ),
          ),
        ),
        const SizedBox(width: 8),
        SmallButton(
          label: _isGoingTo ? 'Moving...' : 'Go To',
          icon: _isGoingTo ? SkotiqIcons.loading : LucideIcons.navigation,
          colors: colors,
          isEnabled: canGoTo,
          onTap: _goToAngle,
        ),
      ],
    );
  }

  Widget _buildSyncSection(
    SkotiqColors colors, {
    required bool canSync,
  }) {
    final syncEnabled =
        _isConnected && !_isMoving && !_isCommandInFlight && canSync;
    return Row(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: colors.background,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
              border: Border.all(color: colors.border),
            ),
            child: TextField(
              controller: _syncController,
              style: SkotiqTypography.bodySm
                  .copyWith(color: colors.textPrimary),
              decoration: InputDecoration(
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: InputBorder.none,
                isDense: true,
                hintText: 'Sky PA 0 - 360',
                hintStyle: SkotiqTypography.caption
                    .copyWith(color: colors.textMuted),
                suffixText: '°',
                suffixStyle: SkotiqTypography.caption
                    .copyWith(color: colors.textMuted),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              enabled: syncEnabled,
              onSubmitted: (_) {
                if (syncEnabled) _syncToPa();
              },
            ),
          ),
        ),
        const SizedBox(width: 8),
        SmallButton(
          label: 'Sync',
          icon: LucideIcons.link,
          colors: colors,
          isEnabled: syncEnabled,
          onTap: _syncToPa,
        ),
      ],
    );
  }

  /// Six always-visible step buttons laid out as two flexible rows.
  Widget _buildRelativeMoveSection(SkotiqColors colors) {
    final canMove = _isConnected && !_isMoving && !_isCommandInFlight;

    Widget row(List<double> steps) {
      final cells = <Widget>[];
      for (final step in steps) {
        if (cells.isNotEmpty) cells.add(const SizedBox(width: 8));
        cells.add(
          Expanded(
            child: _RelativeMoveButton(
              label: '${step > 0 ? '+' : ''}${step.toInt()}°',
              colors: colors,
              onPressed: canMove ? () => _moveRelative(step) : null,
            ),
          ),
        );
      }
      return Row(children: cells);
    }

    return Column(
      children: [
        row(const [-15, -5, -1]),
        const SizedBox(height: 8),
        row(const [1, 5, 15]),
      ],
    );
  }
}

class _RelativeMoveButton extends StatefulWidget {
  final String label;
  final SkotiqColors colors;
  final VoidCallback? onPressed;

  const _RelativeMoveButton({
    required this.label,
    required this.colors,
    this.onPressed,
  });

  @override
  State<_RelativeMoveButton> createState() => _RelativeMoveButtonState();
}

class _RelativeMoveButtonState extends State<_RelativeMoveButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final isEnabled = widget.onPressed != null;
    final textColor =
        isEnabled ? widget.colors.textPrimary : widget.colors.textMuted;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          // The buttons are laid out in flexible cells, so the box is wider
          // than its label; centre it rather than letting it hug the left edge.
          alignment: Alignment.center,
          decoration: _isHovered && isEnabled
              ? SkotiqDecorations.selectedSurface(
                  widget.colors.primary,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusMd),
                )
              : BoxDecoration(
                  color: widget.colors.background,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusMd),
                  border: Border.all(color: widget.colors.border),
                ),
          // The cells are flexible, so the box narrows with the panel. Left as
          // a plain Text the label word-wrapped at the hyphen below ~290 px —
          // "-15°" became a line reading "-" over a line reading "15°" — and
          // the imaging side panel goes down to 250 px (minPanelWidth) with the
          // tablet split clamping as low as 220. Scale the label down instead:
          // a step button must always read as one token.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              widget.label,
              maxLines: 1,
              softWrap: false,
              style: SkotiqTypography.readoutXs.copyWith(color: textColor),
            ),
          ),
        ),
      ),
    );
  }
}

/// Custom painter that draws a circular angle indicator with a needle.
class _AngleIndicatorPainter extends CustomPainter {
  final double angle;
  final Color primaryColor;
  final Color trackColor;
  final bool isConnected;

  _AngleIndicatorPainter({
    required this.angle,
    required this.primaryColor,
    required this.trackColor,
    required this.isConnected,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;

    // Draw track circle
    final trackPaint = Paint()
      ..color = trackColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(center, radius, trackPaint);

    if (!isConnected) return;

    // Draw filled arc from 0 to current angle
    final arcPaint = Paint()
      ..color = primaryColor.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill;

    final arcRect = Rect.fromCircle(center: center, radius: radius);
    // Convert angle to radians, starting from top (north = -pi/2)
    final sweepRadians = angle * math.pi / 180.0;
    canvas.drawArc(arcRect, -math.pi / 2, sweepRadians, true, arcPaint);

    // Draw needle
    final needleRadians = (angle - 90) * math.pi / 180.0;
    final needleEnd = Offset(
      center.dx + radius * math.cos(needleRadians),
      center.dy + radius * math.sin(needleRadians),
    );

    final needlePaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, needleEnd, needlePaint);

    // Draw center dot
    final dotPaint = Paint()
      ..color = primaryColor
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, 3, dotPaint);
  }

  @override
  bool shouldRepaint(_AngleIndicatorPainter oldDelegate) {
    return oldDelegate.angle != angle ||
        oldDelegate.isConnected != isConnected ||
        oldDelegate.primaryColor != primaryColor;
  }
}
