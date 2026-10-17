import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../utils/on_screen_animation_gate.dart';

/// Visual treatment for [StatusDot].
enum StatusDotVariant {
  /// Solid circle, no animation.
  static,

  /// Single 400ms opacity flash when [StatusDot.color] or [variant] changes.
  attention,

  /// Slow opacity pulse reserved for recovery/error urgency.
  urgent,
}

/// Small status indicator — a 7px circle.
///
/// Replaces ad-hoc pulsing dots across the app with a consistent, quieter
/// motion language: static by default, a one-shot flash on meaningful
/// transitions, and a slow pulse — for [urgentPulseWindow], then steady — only
/// for urgent error/recovery states.
class StatusDot extends StatefulWidget {
  /// How long an urgent dot pulses before settling to a steady, full-opacity
  /// dot.
  ///
  /// The pulse exists to draw the eye to a state change; it does not need to
  /// run for as long as the state lasts. Left unbounded it did: a run that
  /// FAILED left the status bar's red dot pulsing at 61 fps — a full-window
  /// frame per vsync on the Linux embedder — for **32.7% of a core,
  /// indefinitely**, on an app doing nothing (measured on the release
  /// bundle). Ten cycles is long enough to be noticed from across a dark
  /// room; after that the dot stays red and stays still, which says the same
  /// thing.
  static const Duration urgentPulseWindow = Duration(seconds: 20);

  /// The dot's diameter in logical pixels (02 vocabulary: a status dot is 7).
  static const double defaultSize = 7.0;

  /// Radius of the live halo drawn outside the dot, in logical pixels.
  static const double liveHaloWidth = 3.0;

  final Color color;
  final double size;
  final StatusDotVariant variant;

  /// Draws the static 3px halo in `success` at
  /// [SkotiqTokens.opacityLiveHalo] around the dot.
  ///
  /// STATIC, deliberately: a live indicator is the only thing in the app
  /// allowed to stand out at rest, and a pulse would be a continuous animation
  /// — the class of defect that once burned 32% of a core on an idle window.
  /// The halo says "live" without asking for a frame.
  final bool live;

  const StatusDot({
    super.key,
    required this.color,
    this.size = defaultSize,
    this.variant = StatusDotVariant.static,
    this.live = false,
  });

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  static const _attentionDuration = Duration(milliseconds: 400);

  late AnimationController _controller;
  Animation<double> _opacity = const AlwaysStoppedAnimation(1.0);

  /// Armed on entering [StatusDotVariant.urgent]; when it fires the pulse
  /// settles. Re-armed whenever the variant becomes urgent again.
  Timer? _urgentPulseTimer;
  bool _urgentPulseSettled = false;

  /// Test-only view of the pulse controller.
  @visibleForTesting
  AnimationController get debugControllerForTesting => _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _applyVariant();
  }

  @override
  void didUpdateWidget(StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    final variantChanged = oldWidget.variant != widget.variant;
    final colorChanged = oldWidget.color != widget.color;

    if (variantChanged) {
      _applyVariant();
    }

    if (widget.variant == StatusDotVariant.attention &&
        (variantChanged || colorChanged)) {
      _flashAttention();
    }
  }

  void _applyVariant() {
    _controller.stop();
    _urgentPulseTimer?.cancel();
    _urgentPulseTimer = null;
    _urgentPulseSettled = false;

    switch (widget.variant) {
      case StatusDotVariant.static:
        _controller.duration = SkotiqTokens.durationNormal;
        _opacity = const AlwaysStoppedAnimation(1.0);
        _controller.value = 0.0;
      case StatusDotVariant.attention:
        _controller.duration = _attentionDuration;
        _opacity = TweenSequence<double>([
          TweenSequenceItem(
            tween: Tween<double>(begin: 1.0, end: 0.35),
            weight: 50,
          ),
          TweenSequenceItem(
            tween: Tween<double>(begin: 0.35, end: 1.0),
            weight: 50,
          ),
        ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
        _controller.value = 0.0;
      case StatusDotVariant.urgent:
        // The pulse is deliberately NOT started here. An urgent dot is a
        // long-lived state, and one parked off screen (an unselected tab, a
        // collapsed panel) would re-schedule a frame on every vsync for as
        // long as it stayed urgent, stopping the whole app from ever idling.
        // [OnScreenAnimationGate] in build() runs it only while the dot is
        // actually being drawn.
        _controller.duration = SkotiqTokens.durationPulse;
        _opacity = Tween<double>(begin: 0.55, end: 1.0).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
        );
        _urgentPulseTimer = Timer(
          StatusDot.urgentPulseWindow,
          _settleUrgentPulse,
        );
    }
  }

  /// The attention has been drawn; hold the dot at full opacity and stop
  /// asking for frames. The gate sees `repeating: false` on the rebuild and
  /// releases the controller it started.
  void _settleUrgentPulse() {
    _urgentPulseTimer = null;
    if (!mounted) {
      return;
    }
    _controller
      ..stop()
      ..value = 1.0;
    setState(() => _urgentPulseSettled = true);
  }

  void _flashAttention() {
    _controller
      ..stop()
      ..value = 0.0
      ..forward();
  }

  @override
  void dispose() {
    _urgentPulseTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.variant == StatusDotVariant.static) {
      return _dot(opacity: 1.0);
    }

    // `repeating` is only true for the urgent pulse, and only until its window
    // has run out; the one-shot `attention` flash drives the same controller
    // with forward(), and the gate leaves animations it did not start alone.
    return OnScreenAnimationGate(
      controller: _controller,
      repeating:
          widget.variant == StatusDotVariant.urgent && !_urgentPulseSettled,
      reverse: true,
      child: AnimatedBuilder(
        animation: _opacity,
        builder: (context, _) => _dot(opacity: _opacity.value),
      ),
    );
  }

  Widget _dot({required double opacity}) {
    final colors = SkotiqColors.of(context);
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.color.withValues(alpha: opacity),
        shape: BoxShape.circle,
        boxShadow: widget.live
            ? <BoxShadow>[
                // No blur and no offset: this is a ring, not a glow.
                BoxShadow(
                  color: colors.success.withValues(
                    alpha: SkotiqTokens.opacityLiveHalo * opacity,
                  ),
                  spreadRadius: StatusDot.liveHaloWidth,
                ),
              ]
            : null,
      ),
    );
  }
}
