import 'package:flutter/material.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';

enum StatusPillStatus { active, warning, error, inactive, success }

class StatusPill extends StatefulWidget {
  final IconData icon;

  /// Leading label rendered as `'$label: $value'`. Pass an empty string for a
  /// value-only pill (`'$value'` with no prefix) when the surrounding UI
  /// already names what the value refers to.
  final String label;
  final String value;
  final StatusPillStatus status;
  final VoidCallback? onTap;

  const StatusPill({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.status = StatusPillStatus.inactive,
    this.onTap,
  });

  @override
  State<StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<StatusPill>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  bool _isFocused = false;
  late AnimationController _flashController;
  late Animation<double> _flashAnimation;
  StatusPillStatus? _previousStatus;

  @override
  void initState() {
    super.initState();
    // The flash controller is created exactly ONCE for the life of the State:
    // SingleTickerProviderStateMixin allows only one ticker, so recreating it
    // on a status change throws "multiple tickers were created" and leaves an
    // orphaned controller ticking. The single controller is re-triggered on
    // each status transition instead.
    _flashController = AnimationController(
      vsync: this,
      duration: SkotiqTokens.durationSmooth,
    );
    _flashAnimation = Tween<double>(
      begin: 1.0,
      end: 1.35,
    ).animate(CurvedAnimation(parent: _flashController, curve: Curves.easeOut));
    _applyFlashForStatus();
  }

  @override
  void didUpdateWidget(StatusPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status != widget.status) {
      _previousStatus = oldWidget.status;
      _applyFlashForStatus();
    }
  }

  /// Drives the (already-created) flash controller for the current status.
  ///
  /// Flashes once when the pill transitions INTO the success state; otherwise
  /// resets the controller to its rest value. Never creates a new controller.
  void _applyFlashForStatus() {
    final shouldFlash =
        widget.status == StatusPillStatus.success &&
        _previousStatus != StatusPillStatus.success;

    if (shouldFlash) {
      _flashController.forward(from: 0.0).then((_) {
        if (mounted) _flashController.reverse();
      });
    } else {
      _flashController.value = 0.0;
    }
  }

  @override
  void dispose() {
    _flashController.dispose();
    super.dispose();
  }

  Color _getStatusColor(SkotiqColors colors) {
    switch (widget.status) {
      case StatusPillStatus.active:
        return colors.success;
      case StatusPillStatus.success:
        return colors.success;
      case StatusPillStatus.warning:
        return colors.warning;
      case StatusPillStatus.error:
        return colors.error;
      case StatusPillStatus.inactive:
        return colors.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final statusColor = _getStatusColor(colors);
    final isLive = widget.status != StatusPillStatus.inactive;

    final pill = MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: SkotiqTokens.durationQuick,
          curve: SkotiqTokens.curveSnappy,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _isHovered ? colors.surfaceHover : colors.surfaceAlt,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
            border: Border.all(
              color: isLive
                  ? statusColor.withValues(alpha: 0.28)
                  : colors.border.withValues(alpha: 0.75),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedBuilder(
                animation: _flashAnimation,
                builder: (context, child) {
                  return Container(
                    width: 6 * _flashAnimation.value,
                    height: 6 * _flashAnimation.value,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  );
                },
              ),
              const SizedBox(width: 6),
              Icon(
                widget.icon,
                size: SkotiqTokens.iconXs,
                color: colors.textSecondary,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  widget.label.isEmpty
                      ? widget.value
                      : '${widget.label}: ${widget.value}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.textSecondary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // A pill is decorative until it is given an onTap; then it is a button and
    // has to be reachable and announced as one. Wrapping unconditionally would
    // put a tab stop on every read-only status readout in the app, which is its
    // own accessibility problem.
    if (widget.onTap == null) return pill;

    return Semantics(
      // Semantics publishes isEnabled only when this field is given;
      // omitting it makes assistive tech announce a live control as
      // disabled. Measured on the running app 2026-08-09.
      enabled: true,
      button: true,
      label: '${widget.label} ${widget.value}',
      onTap: widget.onTap,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (focused) => setState(() => _isFocused = focused),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap!();
              return null;
            },
          ),
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
            border: Border.all(
              color: _isFocused
                  ? context.skotiqColors.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
          // The pill's own GestureDetector publishes a second, role-less node
          // carrying the same text, which AT-SPI renders as a disabled panel
          // sitting inside the button. One control, one node.
          child: ExcludeSemantics(child: pill),
        ),
      ),
    );
  }
}
