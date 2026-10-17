// Step-by-step progress UI for the polar alignment routine: per-measurement tiles, progress steps and connectors, instruction lines, error read-outs, and the spinner that ticks elapsed seconds while a solve is running.
part of '../polar_alignment_screen.dart';

class _MeasurementProgressItem extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final bool isActive;
  final bool isComplete;

  const _MeasurementProgressItem({
    required this.colors,
    required this.label,
    required this.isActive,
    required this.isComplete,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: isComplete
                ? colors.success
                : isActive
                    ? colors.primary.withValues(alpha: 0.2)
                    : colors.surfaceAlt,
            shape: BoxShape.circle,
            border: Border.all(
              color: isComplete
                  ? colors.success
                  : isActive
                      ? colors.primary
                      : colors.border,
              width: 2,
            ),
          ),
          child: Center(
            child: isComplete
                ? Icon(SkotiqIcons.check,
                    size: 12, color: colors.background)
                : isActive
                    ? SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.primary,
                        ),
                      )
                    : null,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize12,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
            color:
                isComplete || isActive ? colors.textPrimary : colors.textMuted,
          ),
        ),
        if (isComplete) ...[
          const Spacer(),
          Icon(SkotiqIcons.success, size: 14, color: colors.success),
        ],
      ],
    );
  }
}

class _ProgressStep extends StatelessWidget {
  final SkotiqColors colors;
  final int number;
  final String label;
  final bool isActive;
  final bool isComplete;

  const _ProgressStep({
    required this.colors,
    required this.number,
    required this.label,
    required this.isActive,
    required this.isComplete,
  });

  @override
  Widget build(BuildContext context) {
    final color = isComplete
        ? colors.success
        : isActive
            ? colors.primary
            : colors.textMuted;

    return Column(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: isComplete || isActive
                ? color.withValues(alpha: 0.2)
                : colors.surfaceAlt,
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
          child: Center(
            child: isComplete
                ? Icon(SkotiqIcons.check, size: 16, color: color)
                : Text(
                    number.toString(),
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      fontWeight: FontWeight.bold,
                      color: color,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize10,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _ProgressConnector extends StatelessWidget {
  final SkotiqColors colors;
  final bool isComplete;

  const _ProgressConnector({
    required this.colors,
    required this.isComplete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 2,
      margin: const EdgeInsets.only(bottom: 18),
      color: isComplete ? colors.success : colors.border,
    );
  }
}

/// Task 4.4: Solve progress indicator with timer
class _SolveProgressIndicator extends StatefulWidget {
  final SkotiqColors colors;
  final String status;

  const _SolveProgressIndicator({
    required this.colors,
    required this.status,
  });

  @override
  State<_SolveProgressIndicator> createState() =>
      _SolveProgressIndicatorState();
}

class _SolveProgressIndicatorState extends State<_SolveProgressIndicator> {
  late DateTime _startTime;
  late Stream<int> _timerStream;

  @override
  void initState() {
    super.initState();
    _startTime = DateTime.now();
    _timerStream = Stream.periodic(
      const Duration(seconds: 1),
      (count) => count + 1,
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: _timerStream,
      builder: (context, snapshot) {
        final elapsed = DateTime.now().difference(_startTime);
        final seconds = elapsed.inSeconds;

        return Row(
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: widget.colors.primary,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.status,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      color: widget.colors.textSecondary,
                    ),
                  ),
                  Text(
                    '${seconds}s elapsed',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      color: widget.colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
