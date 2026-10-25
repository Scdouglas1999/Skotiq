import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A titled panel of the Activity tab: surface tone, hairline border, the
/// section title with an optional note and trailing control.
class ActivityPanel extends StatelessWidget {
  const ActivityPanel({
    super.key,
    required this.title,
    required this.child,
    this.note,
    this.trailing,
  });

  final String title;
  final String? note;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceXl,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceXl,
        SkotiqTokens.spaceLg,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: SkotiqTokens.borderRadiusLg,
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: SkotiqTypography.sectionTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              if (note != null) ...[
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Text(
                    note!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ] else
                const Spacer(),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          child,
        ],
      ),
    );
  }
}

/// A plain sentence inside a panel with nothing to list.
class ActivityQuiet extends StatelessWidget {
  const ActivityQuiet(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
        child: Text(
          text,
          style: SkotiqTypography.bodySm.copyWith(
            color: context.skotiqColors.textSecondary,
          ),
        ),
      );
}

/// The icon and color a night-end step state is drawn with.
(IconData, Color) stepLook(NightEndStepState state, SkotiqColors colors) =>
    switch (state) {
      NightEndStepState.done => (SkotiqIcons.success, colors.success),
      NightEndStepState.failed => (SkotiqIcons.error, colors.error),
      NightEndStepState.waiting => (SkotiqIcons.warning, colors.warning),
      NightEndStepState.running => (SkotiqIcons.loading, colors.info),
      NightEndStepState.skipped => (SkotiqIcons.remove, colors.textMuted),
      NightEndStepState.pending => (SkotiqIcons.circle, colors.textMuted),
    };

/// A step state in words, for screen readers and the row's status column.
String stepWord(NightEndStepState state) => switch (state) {
      NightEndStepState.done => 'Done',
      NightEndStepState.failed => 'Failed',
      NightEndStepState.waiting => 'Waits for you',
      NightEndStepState.running => 'Running',
      NightEndStepState.skipped => 'Skipped',
      NightEndStepState.pending => 'Not yet',
    };

/// `Oct 24 to 25`: the observing night [time] belongs to.
String nightLabel(DateTime time) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final local = time.toLocal();
  final evening = local.hour < 12
      ? DateTime(local.year, local.month, local.day - 1)
      : DateTime(local.year, local.month, local.day);
  final morning = evening.add(const Duration(days: 1));
  final end = morning.month == evening.month
      ? '${morning.day}'
      : '${months[morning.month - 1]} ${morning.day}';
  return '${months[evening.month - 1]} ${evening.day} to $end';
}

/// `05:42`, local time.
String clockLabel(DateTime time) {
  final local = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}';
}

/// `1 h 05 min`, `12 min` or `40 s`.
String durationLabel(Duration d) {
  if (d.inMinutes < 1) return '${d.inSeconds} s';
  if (d.inHours < 1) return '${d.inMinutes} min';
  return '${d.inHours} h ${(d.inMinutes % 60).toString().padLeft(2, '0')} min';
}
