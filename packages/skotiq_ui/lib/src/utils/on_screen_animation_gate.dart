import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Keeps a repeating [AnimationController] from running while nothing is
/// actually on screen to show for it.
///
/// ## Why this exists
///
/// A repeating `AnimationController` re-schedules a frame on every vsync for as
/// long as it runs. One of them, anywhere in the tree, is enough to stop the
/// whole application from ever idling: the engine produces frames continuously,
/// every screen renders at a degraded framerate, and the machine never gets to
/// rest. It costs the same whether the animation is visible or not.
///
/// That made an unconditional `_controller.repeat()` in `initState` a trap. It
/// looks local and harmless, but it is only correct while the widget is both
/// mounted *and* on screen — and nothing enforces that. Skotiq shipped
/// exactly this bug: a shell-mounted overlay pulsed an icon it only ever draws
/// during an autofocus run, so from launch to quit the app produced ~45 frames
/// per second with a 2%-busy GPU and nothing to draw.
///
/// [TickerMode] already covers the case where a whole route or subtree is
/// deactivated — [SingleTickerProviderStateMixin] mutes its ticker, and a muted
/// ticker stops scheduling. What it does *not* cover is a widget that is mounted
/// and nominally "enabled" but is not being drawn: an [Offstage] child, the
/// unselected branch of an [IndexedStack], or a widget whose own build returns
/// nothing to paint.
///
/// This gate closes that gap by tying the animation to the only thing that
/// actually matters — whether the subtree gets painted. If the controller ticks
/// without the child painting, the animation is invisible, so it is stopped. The
/// moment the child paints again, it resumes. Callers get correct default
/// behaviour without having to remember anything.
///
/// ## Usage
///
/// Own the controller as usual, but never call `repeat()` yourself. Wrap the
/// animated subtree and declare *whether* the animation is wanted; the gate
/// decides when it may actually run.
///
/// ```dart
/// OnScreenAnimationGate(
///   controller: _controller,
///   repeating: widget.isLoading,
///   child: AnimatedBuilder(
///     animation: _controller,
///     builder: (context, _) => ...,
///   ),
/// )
/// ```
///
/// The gate only ever stops an animation it started itself, so a controller that
/// is also driven directly (a one-shot `forward()`, say) is left alone.
class OnScreenAnimationGate extends StatefulWidget {
  const OnScreenAnimationGate({
    super.key,
    required this.controller,
    required this.repeating,
    required this.child,
    this.reverse = false,
  });

  /// The controller to drive. Owned and disposed by the caller.
  final AnimationController controller;

  /// Whether the caller wants the animation to run at all — the real state
  /// ("is something loading", "is this status urgent"). The gate ANDs this with
  /// "is the child actually being painted".
  final bool repeating;

  /// Forwarded to [AnimationController.repeat].
  final bool reverse;

  /// The subtree that renders the animation. Painting of this subtree is what
  /// the gate observes.
  final Widget child;

  @override
  State<OnScreenAnimationGate> createState() => _OnScreenAnimationGateState();
}

class _OnScreenAnimationGateState extends State<OnScreenAnimationGate> {
  /// Ticks the gate tolerates without a paint before concluding the animation is
  /// invisible. The first tick of a newly started animation legitimately runs
  /// before the first paint, so a budget of 1 would stop it immediately.
  static const int _unpaintedTickBudget = 2;

  /// Assume visible until proven otherwise, so a normally-visible widget starts
  /// animating on its first frame rather than after a paint round-trip.
  bool _onScreen = true;
  bool _startedByGate = false;
  bool _paintedSinceLastTick = false;
  int _unpaintedTicks = 0;
  bool _resumeScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleTick);
    _sync();
  }

  @override
  void didUpdateWidget(OnScreenAnimationGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_handleTick);
      // The old controller is the caller's to dispose, but we must not leave it
      // repeating on our behalf after we have stopped watching it.
      if (_startedByGate && oldWidget.controller.isAnimating) {
        oldWidget.controller.stop();
      }
      _startedByGate = false;
      widget.controller.addListener(_handleTick);
    }
    _sync();
  }

  @override
  void dispose() {
    // Both calls below are documented as safe on an already-disposed controller
    // (removeListener explicitly allows it; isAnimating reads false once the
    // ticker is gone), which matters because the owning State may go down in
    // either order relative to this one.
    widget.controller.removeListener(_handleTick);
    if (_startedByGate && widget.controller.isAnimating) {
      // Never leave a repeat running that only this gate knew about.
      _startedByGate = false;
      widget.controller.stop();
    }
    super.dispose();
  }

  /// Runs during the transient-callback phase, i.e. before this frame's paint,
  /// so it is judging whether the PREVIOUS frame painted the child.
  void _handleTick() {
    if (!_startedByGate) {
      return;
    }
    if (_paintedSinceLastTick) {
      _paintedSinceLastTick = false;
      _unpaintedTicks = 0;
      return;
    }
    _unpaintedTicks++;
    if (_unpaintedTicks < _unpaintedTickBudget) {
      return;
    }
    // Ticking with nothing being drawn: the animation is invisible and is only
    // costing the app its idle. Stopping inside the controller's own listener is
    // safe — the ticker will simply not re-schedule itself.
    _onScreen = false;
    _unpaintedTicks = 0;
    _startedByGate = false;
    widget.controller.stop();
  }

  void _handlePaint() {
    _paintedSinceLastTick = true;
    if (_onScreen || _resumeScheduled) {
      return;
    }
    // Back on screen. The controller cannot be touched here: notifying its
    // listeners mid-paint would mark widgets dirty during the paint phase.
    _resumeScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _resumeScheduled = false;
      if (!mounted) {
        return;
      }
      _onScreen = true;
      _unpaintedTicks = 0;
      _sync();
      // _sync() opens a fresh unpainted budget, which would throw away the very
      // paint that got us here. Without this the gate oscillates: stop on the
      // budget, resume on the next paint, stop again — an animation whose only
      // repaint trigger is itself then advances on every other frame.
      _paintedSinceLastTick = true;
    });
  }

  void _sync() {
    if (widget.repeating && _onScreen) {
      if (!widget.controller.isAnimating) {
        _startedByGate = true;
        _paintedSinceLastTick = false;
        _unpaintedTicks = 0;
        widget.controller.repeat(reverse: widget.reverse);
      }
    } else if (_startedByGate) {
      _startedByGate = false;
      widget.controller.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return _PaintObserver(onPaint: _handlePaint, child: widget.child);
  }
}

/// Invokes [onPaint] every time its child is painted.
class _PaintObserver extends SingleChildRenderObjectWidget {
  const _PaintObserver({required this.onPaint, required Widget super.child});

  final VoidCallback onPaint;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPaintObserver(onPaint);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderPaintObserver renderObject,
  ) {
    renderObject.onPaint = onPaint;
  }
}

class _RenderPaintObserver extends RenderProxyBox {
  _RenderPaintObserver(this.onPaint);

  VoidCallback onPaint;

  @override
  void paint(PaintingContext context, Offset offset) {
    onPaint();
    super.paint(context, offset);
  }
}
