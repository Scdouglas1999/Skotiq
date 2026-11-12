import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A button that requires a deliberate press-and-hold gesture before firing
/// its [onConfirmed] callback. Designed for destructive actions on touch
/// devices where a stray tap (thumb-slip, glove, phone in pocket pressing
/// against the screen) must NOT trigger irreversible state changes.
///
/// The hold starts the moment the pointer goes down: a fill sweeps across the
/// wrapped [child] and a ring traces its edge, both from the first frame, so
/// the press visibly does something. The callback fires exactly once when
/// they complete. Releasing early aborts the gesture and drains them, and a
/// press too short to be a hold shows [confirmText] ("Hold to stop") as a
/// tooltip, so a click that did nothing says what would.
///
/// Why not a confirm dialog? Dialogs interrupt at-a-glance monitoring (the
/// canonical use case for this widget is the Stop button on a multi-hour
/// imaging sequence). A hold gesture is deliberate but does not block the
/// user from seeing what the rest of the screen is doing.
///
/// Accessibility: a screen reader's activate or long-press action confirms
/// at once; choosing the button and activating it is already deliberate, and
/// such a user may have no way to hold. Respects
/// [MediaQueryData.disableAnimations]. When animations
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

  /// How long the user must hold, counted from the press. Two seconds:
  /// long enough to be deliberate, short enough that a user who genuinely
  /// wants to stop the sequence does not feel like they are fighting the UI.
  final Duration duration;

  /// What the gesture asks for, e.g. "Hold to stop": the tooltip on hover,
  /// while the user holds and after a press too short to count. Null
  /// reads "Press and hold to confirm".
  final String? confirmText;

  /// When false, all gestures are ignored and the visual stays in its
  /// disabled appearance (delegated to the wrapped [child]).
  final bool enabled;

  /// Color of the progress ring while the user is holding. Defaults to the
  /// theme's error color (since this is intended for destructive actions).
  final Color? holdColor;

  final double ringStrokeWidth;

  /// What the button does, for screen readers ("Stop the run"). It names the
  /// action, not the hold: their activate action confirms at once.
  final String? semanticsLabel;

  const HoldToConfirmButton({
    super.key,
    required this.child,
    required this.onConfirmed,
    this.duration = const Duration(seconds: 2),
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

  final GlobalKey<TooltipState> _tooltip = GlobalKey<TooltipState>();

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

  void _confirmFromSemantics() {
    if (!widget.enabled) return;
    HapticFeedback.heavyImpact();
    widget.onConfirmed();
  }

  Offset? _pressedAt;

  void _onPointerDown(PointerDownEvent event) {
    // A right or middle click is not a press of the button.
    if (event.buttons & kPrimaryButton == 0) return;
    _pressedAt = event.position;
    _handleHoldStart();
    // After the frame: the tooltip closes itself on any pointer down,
    // this one included, once this handler returns.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _holding) _tooltip.currentState?.ensureTooltipVisible();
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    final start = _pressedAt;
    if (start == null) return;
    if ((event.position - start).distance > kTouchSlop) {
      _pressedAt = null;
      _cancelHold();
    }
  }

  /// The press ended before the hold completed: say what the gesture is.
  void _releaseHold() {
    _pressedAt = null;
    final released = _holding && !_confirmedThisHold;
    _cancelHold();
    if (released) _tooltip.currentState?.ensureTooltipVisible();
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
    final ask = widget.confirmText ?? 'Press and hold to confirm';

    // A pointer has to hold; assistive technology has no stray touches, so
    // its activate and long-press actions confirm at once. Without them a
    // screen reader could read the button and never press it.
    final confirm = widget.enabled ? _confirmFromSemantics : null;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.semanticsLabel ?? 'Confirm',
      onTap: confirm,
      onLongPress: confirm,
      child: Tooltip(
        key: _tooltip,
        message: widget.enabled ? ask : '',
        // Touch would otherwise open the tooltip on a long press, which is
        // the very gesture this button is for.
        triggerMode: TooltipTriggerMode.manual,
        // Raw pointer events, not a recognizer: the hold starts at the press
        // instead of half a second into it, and no long-press recognizer
        // around the button (a tooltip's, on touch) can win the arena and
        // end the hold early. Moving off past the touch slop, as a scroll
        // does, cancels it.
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: widget.enabled ? _onPointerDown : null,
          onPointerMove: widget.enabled ? _onPointerMove : null,
          onPointerUp: widget.enabled ? (_) => _releaseHold() : null,
          onPointerCancel: widget.enabled ? (_) => _cancelHold() : null,
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
                          painter: _HoldPainter(
                            progress: _controller.value,
                            color: ringColor,
                            strokeWidth: widget.ringStrokeWidth,
                          ),
                        );
                      },
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

/// The hold's progress: a translucent fill sweeping left to right across the
/// button and a ring tracing its edge.
class _HoldPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double strokeWidth;

  _HoldPainter({
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

    final sweep = progress.clamp(0.0, 1.0);
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * sweep, size.height));
    canvas.drawRRect(rrect, Paint()..color = color.withValues(alpha: 0.45));
    canvas.restore();

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
  bool shouldRepaint(covariant _HoldPainter old) {
    return old.progress != progress ||
        old.color != color ||
        old.strokeWidth != strokeWidth;
  }
}
