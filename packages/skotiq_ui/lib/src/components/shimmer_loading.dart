import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../utils/on_screen_animation_gate.dart';

/// A shimmer loading effect for skeleton screens
class ShimmerLoading extends StatefulWidget {
  final Widget child;
  final bool isLoading;
  final Duration duration;
  final bool useAccentTint;

  const ShimmerLoading({
    super.key,
    required this.child,
    this.isLoading = true,
    this.duration = SkotiqTokens.durationShimmer,
    this.useAccentTint = false,
  });

  @override
  State<ShimmerLoading> createState() => _ShimmerLoadingState();
}

class _ShimmerLoadingState extends State<ShimmerLoading>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  // Cache colors to avoid repeated lookups every frame
  List<Color>? _cachedColors;

  // The shimmer animation is an expensive per-frame ShaderMask. On a remote
  // slave an async provider can sit in its `loading` state effectively forever,
  // which would keep every skeleton repainting at ~60Hz indefinitely. Cap how
  // long we animate: after this the skeleton stays visible but static.
  static const Duration _shimmerAnimateCap = Duration(seconds: 6);
  Timer? _capTimer;
  bool _capReached = false;

  // Whether the shimmer WANTS to animate. Whether it actually may is decided by
  // [OnScreenAnimationGate], which additionally requires the skeleton to be on
  // screen. Never call `_controller.repeat()` directly here — an unconditional
  // repeat is what pins the whole app off idle.
  bool get _wantsShimmer => widget.isLoading && !_capReached;

  void _startShimmer() {
    _capTimer?.cancel();
    _capReached = false;
    _capTimer = Timer(_shimmerAnimateCap, () {
      if (!mounted || _capReached) {
        return;
      }
      setState(() => _capReached = true);
    });
  }

  void _stopShimmer() {
    _capTimer?.cancel();
    _capReached = false;
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    if (widget.isLoading) {
      _startShimmer();
    }
  }

  @override
  void didUpdateWidget(ShimmerLoading oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Drive on the isLoading TRANSITION (not on isAnimating) so the cap timer
    // isn't restarted on every unrelated rebuild.
    if (widget.isLoading && !oldWidget.isLoading) {
      _startShimmer();
    } else if (!widget.isLoading && oldWidget.isLoading) {
      _stopShimmer();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateCachedColors();
  }

  void _updateCachedColors() {
    final colors = context.skotiqColors;
    if (widget.useAccentTint) {
      _cachedColors = [
        colors.surfaceAlt,
        Color.lerp(colors.surfaceHover, colors.primary, 0.04)!,
        colors.surfaceAlt,
      ];
    } else {
      _cachedColors = [
        colors.surfaceAlt,
        colors.surfaceHover,
        colors.surfaceAlt,
      ];
    }
  }

  @override
  void dispose() {
    _capTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoading) {
      return widget.child;
    }

    // Ensure colors are cached
    _cachedColors ??= () {
      _updateCachedColors();
      return _cachedColors!;
    }();

    // RepaintBoundary isolates the per-frame ShaderMask repaint so it can't
    // bubble out and dirty sibling/ancestor widgets every frame.
    return RepaintBoundary(
      child: OnScreenAnimationGate(
        controller: _controller,
        repeating: _wantsShimmer,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return ShaderMask(
              shaderCallback: (bounds) {
                return LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: _cachedColors!,
                  stops: [
                    (_controller.value - 0.3).clamp(0.0, 1.0),
                    _controller.value,
                    (_controller.value + 0.3).clamp(0.0, 1.0),
                  ],
                ).createShader(bounds);
              },
              blendMode: BlendMode.srcATop,
              child: child,
            );
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// A skeleton loading state for loading states
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double borderRadius;

  const SkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.borderRadius = 4,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: colors.border.withValues(alpha: 0.5)),
      ),
    );
  }
}

/// A text-like skeleton loading state
class SkeletonText extends StatelessWidget {
  final double? width;
  final double height;
  final int lines;
  final double spacing;

  const SkeletonText({
    super.key,
    this.width,
    this.height = 12,
    this.lines = 1,
    this.spacing = 8,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    if (lines == 1) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: BorderRadius.circular(height / 2),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(lines, (index) {
        // Make last line shorter for a more natural look
        final lineWidth = index == lines - 1 && width != null
            ? width! * 0.7
            : width;

        return Padding(
          padding: EdgeInsets.only(bottom: index < lines - 1 ? spacing : 0),
          child: Container(
            width: lineWidth,
            height: height,
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: BorderRadius.circular(height / 2),
            ),
          ),
        );
      }),
    );
  }
}
