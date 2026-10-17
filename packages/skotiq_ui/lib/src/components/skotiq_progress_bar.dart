import 'package:flutter/material.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../utils/on_screen_animation_gate.dart';

/// Progress bar style variants
enum SkotiqProgressStyle {
  /// Standard progress bar
  standard,

  /// Thin progress bar (4px height)
  thin,

  /// Thick progress bar (12px height)
  thick,

  /// Segmented progress bar (shows discrete steps)
  segmented,
}

/// Progress bar state for status coloring
enum SkotiqProgressState {
  /// Normal progress (primary color)
  normal,

  /// Success state (success color)
  success,

  /// Warning state (warning color)
  warning,

  /// Error state (error color)
  error,

  /// Paused state (muted color)
  paused,
}

/// A customizable progress bar component.
///
/// Features:
/// - Multiple styles (standard, thin, thick, segmented)
/// - State-based coloring (normal, success, warning, error, paused)
/// - Optional label and percentage display
/// - Animated transitions
/// - Indeterminate mode for unknown progress
class SkotiqProgressBar extends StatelessWidget {
  const SkotiqProgressBar({
    super.key,
    required this.value,
    this.style = SkotiqProgressStyle.standard,
    this.state = SkotiqProgressState.normal,
    this.label,
    this.showPercentage = false,
    this.indeterminate = false,
    this.segments,
    this.height,
    this.backgroundColor,
    this.foregroundColor,
    this.animationDuration,
  });

  /// Progress value from 0.0 to 1.0
  final double value;

  /// Visual style of the progress bar
  final SkotiqProgressStyle style;

  /// State for automatic color selection
  final SkotiqProgressState state;

  /// Optional label shown above the progress bar
  final String? label;

  /// Whether to show percentage text
  final bool showPercentage;

  /// Whether to show indeterminate animation
  final bool indeterminate;

  /// Number of segments (for segmented style)
  final int? segments;

  /// Custom height override
  final double? height;

  /// Custom background color
  final Color? backgroundColor;

  /// Custom foreground color
  final Color? foregroundColor;

  /// Custom animation duration
  final Duration? animationDuration;

  double get _height {
    if (height != null) return height!;
    return switch (style) {
      SkotiqProgressStyle.thin => 4.0,
      SkotiqProgressStyle.standard => 8.0,
      SkotiqProgressStyle.thick => 12.0,
      SkotiqProgressStyle.segmented => 8.0,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    final bgColor = backgroundColor ?? colors.surfaceAlt;
    final fgColor = foregroundColor ?? _getStateColor(colors);

    Widget progressBar;

    if (indeterminate) {
      progressBar = _IndeterminateProgressBar(
        height: _height,
        backgroundColor: bgColor,
        foregroundColor: fgColor,
      );
    } else if (style == SkotiqProgressStyle.segmented && segments != null) {
      progressBar = _SegmentedProgressBar(
        value: value,
        segments: segments!,
        height: _height,
        backgroundColor: bgColor,
        foregroundColor: fgColor,
      );
    } else {
      progressBar = _StandardProgressBar(
        value: value,
        height: _height,
        backgroundColor: bgColor,
        foregroundColor: fgColor,
        animationDuration: animationDuration ?? SkotiqTokens.durationNormal,
      );
    }

    if (label == null && !showPercentage) {
      return progressBar;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null || showPercentage)
          Padding(
            padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceSm),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (label != null)
                  Expanded(
                    child: Text(
                      label!,
                      style: SkotiqTypography.labelSm.copyWith(
                        color: colors.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (showPercentage)
                  Text(
                    '${(value * 100).round()}%',
                    style: SkotiqTypography.monoSm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        progressBar,
      ],
    );
  }

  Color _getStateColor(SkotiqColors colors) {
    return switch (state) {
      SkotiqProgressState.normal => colors.primary,
      SkotiqProgressState.success => colors.success,
      SkotiqProgressState.warning => colors.warning,
      SkotiqProgressState.error => colors.error,
      SkotiqProgressState.paused => colors.textMuted,
    };
  }
}

class _StandardProgressBar extends StatefulWidget {
  const _StandardProgressBar({
    required this.value,
    required this.height,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.animationDuration,
  });

  final double value;
  final double height;
  final Color backgroundColor;
  final Color foregroundColor;
  final Duration animationDuration;

  @override
  State<_StandardProgressBar> createState() => _StandardProgressBarState();
}

class _StandardProgressBarState extends State<_StandardProgressBar> {
  /// Key on the painted fill so tests can measure it directly. Without a
  /// handle on the fill, a bar that renders 100% full at `value: 0` is
  /// indistinguishable from a correct one in a widget test.
  static const fillKey = ValueKey<String>('skotiq-progress-fill');

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final raw = widget.value;
    final fraction = raw.isFinite ? raw.clamp(0.0, 1.0) : 0.0;
    final isComplete = fraction >= 1.0;
    final effectiveFgColor = isComplete
        ? colors.success
        : widget.foregroundColor;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Why the track width is set explicitly and the FILL is a fraction of
        // it, rather than the reverse:
        //
        // Setting the fill's own `width` does not work. `Container(width: w)`
        // lowers to a RenderConstrainedBox whose constraints are `enforce`d
        // against the incoming ones, and a tight parent (`Expanded` inside a
        // `Row` — how almost every call site uses this widget) hands down
        // min == max == full width. The requested fraction width was therefore
        // clamped back UP to the full width and silently discarded, painting
        // every determinate bar 100% full regardless of `value`. Symmetrically,
        // under LOOSE constraints a track sized from the fill shrink-wraps to
        // it instead of spanning its slot.
        final trackWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : null;
        return Container(
          width: trackWidth,
          height: widget.height,
          decoration: BoxDecoration(
            color: widget.backgroundColor,
            borderRadius: BorderRadius.circular(widget.height / 2),
            border: Border.all(color: colors.border.withValues(alpha: 0.45)),
          ),
          clipBehavior: Clip.hardEdge,
          // A bar handed unbounded width cannot express a fraction of its
          // slot; paint the track only rather than guessing (or throwing).
          child: trackWidth == null
              ? null
              : TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: fraction, end: fraction),
                  duration: widget.animationDuration,
                  curve: SkotiqTokens.curvePrecise,
                  builder: (context, animatedFraction, _) {
                    return FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: animatedFraction.clamp(0.0, 1.0),
                      child: DecoratedBox(
                        key: fillKey,
                        decoration: BoxDecoration(
                          color: effectiveFgColor,
                          borderRadius: BorderRadius.circular(
                            widget.height / 2,
                          ),
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}

class _SegmentedProgressBar extends StatelessWidget {
  const _SegmentedProgressBar({
    required this.value,
    required this.segments,
    required this.height,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final double value;
  final int segments;
  final double height;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    final completedSegments = (value * segments).floor();
    final partialProgress = (value * segments) - completedSegments;

    return Row(
      children: List.generate(segments, (index) {
        final isCompleted = index < completedSegments;
        final isPartial = index == completedSegments;

        return Expanded(
          child: Container(
            height: height,
            margin: EdgeInsets.only(right: index < segments - 1 ? 2 : 0),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(height / 2),
            ),
            clipBehavior: Clip.hardEdge,
            child: isCompleted || isPartial
                ? FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: isCompleted ? 1.0 : partialProgress,
                    child: AnimatedContainer(
                      duration: SkotiqTokens.durationNormal,
                      decoration: BoxDecoration(
                        color: foregroundColor,
                        borderRadius: BorderRadius.circular(height / 2),
                      ),
                    ),
                  )
                : null,
          ),
        );
      }),
    );
  }
}

class _IndeterminateProgressBar extends StatefulWidget {
  const _IndeterminateProgressBar({
    required this.height,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final double height;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  State<_IndeterminateProgressBar> createState() =>
      _IndeterminateProgressBarState();
}

class _IndeterminateProgressBarState extends State<_IndeterminateProgressBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _animation = Tween<double>(
      begin: -0.5,
      end: 1.5,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    // Deliberately NOT started here. An indeterminate bar left mounted in a
    // state that never resolves would otherwise re-schedule a frame on every
    // vsync forever and stop the whole app from ever idling.
    // [OnScreenAnimationGate] in build() runs it only while it is on screen.
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        borderRadius: BorderRadius.circular(widget.height / 2),
      ),
      clipBehavior: Clip.hardEdge,
      child: OnScreenAnimationGate(
        controller: _controller,
        repeating: true,
        child: AnimatedBuilder(
          animation: _animation,
          builder: (context, child) {
            return FractionallySizedBox(
              alignment: Alignment((_animation.value * 2) - 1, 0),
              widthFactor: 0.4,
              child: Container(
                decoration: BoxDecoration(
                  color: widget.foregroundColor,
                  borderRadius: BorderRadius.circular(widget.height / 2),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// A circular progress indicator with optional percentage display.
class SkotiqCircularProgress extends StatelessWidget {
  const SkotiqCircularProgress({
    super.key,
    required this.value,
    this.size = 64,
    this.strokeWidth = 6,
    this.state = SkotiqProgressState.normal,
    this.showPercentage = false,
    this.indeterminate = false,
    this.backgroundColor,
    this.foregroundColor,
    this.child,
  });

  /// Progress value from 0.0 to 1.0
  final double value;

  /// Size of the circular progress
  final double size;

  /// Width of the progress stroke
  final double strokeWidth;

  /// State for automatic color selection
  final SkotiqProgressState state;

  /// Whether to show percentage in center
  final bool showPercentage;

  /// Whether to show indeterminate animation
  final bool indeterminate;

  /// Custom background color
  final Color? backgroundColor;

  /// Custom foreground color
  final Color? foregroundColor;

  /// Custom center widget
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    final bgColor = backgroundColor ?? colors.surfaceAlt;
    final fgColor = foregroundColor ?? _getStateColor(colors);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Background circle
          CircularProgressIndicator(
            value: 1.0,
            strokeWidth: strokeWidth,
            backgroundColor: Colors.transparent,
            valueColor: AlwaysStoppedAnimation(bgColor),
            strokeCap: StrokeCap.round,
          ),
          // Progress circle
          if (indeterminate)
            CircularProgressIndicator(
              strokeWidth: strokeWidth,
              valueColor: AlwaysStoppedAnimation(fgColor),
              strokeCap: StrokeCap.round,
            )
          else
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: value.clamp(0.0, 1.0)),
              duration: SkotiqTokens.durationNormal,
              curve: SkotiqTokens.curveStandard,
              builder: (context, animatedValue, _) {
                return CircularProgressIndicator(
                  value: animatedValue,
                  strokeWidth: strokeWidth,
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation(fgColor),
                  strokeCap: StrokeCap.round,
                );
              },
            ),
          // Center content
          if (child != null || showPercentage)
            Center(
              child:
                  child ??
                  Text(
                    '${(value * 100).round()}%',
                    style: SkotiqTypography.monoSm.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
            ),
        ],
      ),
    );
  }

  Color _getStateColor(SkotiqColors colors) {
    return switch (state) {
      SkotiqProgressState.normal => colors.primary,
      SkotiqProgressState.success => colors.success,
      SkotiqProgressState.warning => colors.warning,
      SkotiqProgressState.error => colors.error,
      SkotiqProgressState.paused => colors.textMuted,
    };
  }
}
