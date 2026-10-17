import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A button that requires a deliberate press-and-hold gesture before firing
/// its [onConfirmed] callback. Designed for destructive actions on touch
/// devices where a stray tap (thumb-slip, glove, phone in pocket pressing
/// against the screen) must NOT trigger irreversible state changes.
///
/// While the user is holding, a progress ring fills around the wrapped
/// [child]. The callback fires exactly once when the ring reaches 100%.
/// Releasing early aborts the gesture and reverses the ring.
///
/// Why not a confirm dialog? Dialogs interrupt at-a-glance monitoring (the
/// canonical use case for this widget is the Stop button on a multi-hour
/// imaging sequence). A hold gesture is deliberate but does not block the
/// user from seeing what the rest of the screen is doing.
///
/// Accessibility: respects [MediaQueryData.disableAnimations]. When animations
/// are disabled (e.g., a screen-reader user has "Reduce Motion" on) the
/// progress ring is not drawn, but the hold gesture is still required —
/// the callback fires after [duration] of continuous press, with no visual
/// countdown. This keeps the safety semantics intact for assistive-tech
/// users without spamming the accessibility tree with animation events.
class HoldToConfirmButton extends StatefulWidget {
  /// The widget rendered inside the button (typically an icon + label).
  final Widget child;

  /// Fired when the user has held the button continuously for [duration].
  /// Guaranteed to be called at most once per hold cycle.
  final VoidCallback onConfirmed;

  /// How long the user must hold before the callback fires. Defaults to
  /// 1500ms — long enough to be deliberate, short enough that a user who
  /// genuinely wants to stop the sequence does not feel like they are
  /// fighting the UI.
  final Duration duration;

  /// Optional label shown beneath the child while the user is holding.
  /// e.g. "Hold to stop". If null, no overlay text is drawn.
  final String? confirmText;

  /// When false, all gestures are ignored and the visual stays in its
  /// disabled appearance (delegated to the wrapped [child]).
  final bool enabled;

  /// Color of the progress ring while the user is holding. Defaults to the
  /// theme's error color (since this is intended for destructive actions).
  final Color? holdColor;

  /// Width of the progress-ring stroke.
  final double ringStrokeWidth;

  /// Semantics label override for screen readers. Defaults to
  /// "Press and hold to confirm".
  final String? semanticsLabel;

  const HoldToConfirmButton({
    super.key,
    required this.child,
    required this.onConfirmed,
    this.duration = const Duration(milliseconds: 1500),
    this.confirmText,
    this.enabled = true,
    this.holdColor,
    this.ringStrokeWidth = 3.0,
    this.semanticsLabel,
  });

  @override
  State<HoldToConfirmButton> createState() => _HoldToConfirmButtonState();
}

class _HoldToConfirmButtonState extends State<HoldToConfirmButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  /// True between [_handleHoldStart] and the moment the controller settles
  /// back at 0 (either after confirmation or after a cancelled hold). Used
  /// to draw the progress ring and the confirm-text overlay.
  bool _holding = false;

  /// Guards against firing [onConfirmed] more than once per hold cycle.
  /// AnimationStatus.completed can fire as part of forward()'s completion
  /// future AND as a status callback in some Flutter versions; we want
  /// exactly-once semantics.
  bool _confirmedThisHold = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(covariant HoldToConfirmButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    // If the button becomes disabled mid-hold, abort cleanly so the user
    // doesn't end up in a stuck "holding" visual state when the sequence
    // transitions to e.g. completed underneath them.
    if (oldWidget.enabled && !widget.enabled && _holding) {
      _cancelHold();
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_onStatus);
    _controller.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed &&
        _holding &&
        !_confirmedThisHold) {
      _confirmedThisHold = true;
      // Heavy haptic confirms to the user that the action fired even if
      // the screen is in their peripheral vision.
      HapticFeedback.heavyImpact();
      widget.onConfirmed();
      // Reset visual state so subsequent holds work correctly.
      // We schedule via the framework instead of inline so we don't mutate
      // controller state from inside its own status callback.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _holding = false);
        _controller.value = 0;
      });
    }
  }

  void _handleHoldStart() {
    if (!widget.enabled) return;
    _confirmedThisHold = false;
    // Light haptic on hold start so the user knows the gesture registered.
    HapticFeedback.selectionClick();
    setState(() => _holding = true);

    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (disableAnimations) {
      // Still require the hold duration — animation just isn't drawn.
      // We snap the controller forward after the configured delay so the
      // status listener fires onConfirmed at the same point in time.
      _controller.value = 0;
      Future<void>.delayed(widget.duration, () {
        if (!mounted || !_holding) return;
        _controller.value = 1.0;
      });
    } else {
      _controller.forward(from: 0);
    }
  }

  void _cancelHold() {
    if (!_holding) return;
    setState(() => _holding = false);
    if (_confirmedThisHold) {
      // Already confirmed — _onStatus will handle the reset.
      return;
    }
    // Reverse smoothly so the ring drains visually; if the user re-engages
    // mid-reverse, [_handleHoldStart] will call forward(from: 0) and reset.
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ringColor = widget.holdColor ?? theme.colorScheme.error;

    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.semanticsLabel ?? 'Press and hold to confirm',
      child: Tooltip(
        message: widget.enabled
            ? (widget.confirmText ?? 'Press and hold to confirm')
            : '',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: widget.enabled ? (_) => _handleHoldStart() : null,
          onLongPressEnd: widget.enabled ? (_) => _cancelHold() : null,
          onLongPressCancel: widget.enabled ? _cancelHold : null,
          child: Stack(
            alignment: Alignment.center,
            children: [
              widget.child,
              if (_holding)
                Positioned.fill(
                  child: IgnorePointer(
                    child: AnimatedBuilder(
                      animation: _controller,
                      builder: (context, _) {
                        return CustomPaint(
                          painter: _RingPainter(
                            progress: _controller.value,
                            color: ringColor,
                            strokeWidth: widget.ringStrokeWidth,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              if (_holding && widget.confirmText != null)
                Positioned(
                  bottom: 4,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface.withValues(
                            alpha: 0.85,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          widget.confirmText!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: ringColor,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double strokeWidth;

  _RingPainter({
    required this.progress,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    // Use a rounded rectangle so the ring follows typical button geometry
    // instead of forcing a strict circle (which would look wrong on a
    // wide pill-shaped destructive button).
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(size.shortestSide / 2),
    );

    // Background track (dim) so the user perceives "how far to go".
    final trackPaint = Paint()
      ..color = color.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawRRect(rrect, trackPaint);

    // Foreground arc — clip the rounded rect border to a length based on
    // progress.
    final fgPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final fullPath = Path()..addRRect(rrect);
    final metrics = fullPath.computeMetrics().toList();
    final totalLength = metrics.fold<double>(0, (sum, m) => sum + m.length);
    final target = totalLength * progress.clamp(0.0, 1.0);

    final drawPath = Path();
    var remaining = target;
    for (final m in metrics) {
      if (remaining <= 0) break;
      final take = remaining > m.length ? m.length : remaining;
      drawPath.addPath(m.extractPath(0, take), Offset.zero);
      remaining -= take;
    }
    canvas.drawPath(drawPath, fgPaint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) {
    return old.progress != progress ||
        old.color != color ||
        old.strokeWidth != strokeWidth;
  }
}
