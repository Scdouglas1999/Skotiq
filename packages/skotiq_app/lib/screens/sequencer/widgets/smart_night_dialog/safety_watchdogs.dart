part of '../smart_night_dialog.dart';

// Safety & watchdogs preview section

/// A single parallel-watchdog callout surfaced in the plan preview.
///
/// These describe triggers the executor installs as siblings of the
/// imaging branch — they run in parallel and fire by hour-angle / sensor
/// state, not by list position. Surfacing them in the preview keeps the
/// user's mental model honest: a meridian flip or a weather-park can
/// interrupt the run at any point, regardless of where the target sits in
/// the sequence.
@immutable
class SmartNightWatchdog {
  const SmartNightWatchdog({required this.title, required this.detail});

  /// Short bold lead-in, e.g. "Meridian flip".
  final String title;

  /// Sentence explaining when/how it fires.
  final String detail;
}

/// Derives the parallel-watchdog callouts a [SmartNightPlan] installs,
/// purely from data already present on the plan.
///
/// The injection decisions are NOT re-implemented here — they delegate to
/// the authoritative predicates on [SmartNightService]
/// ([SmartNightService.willInjectMeridianFlip] and
/// [SmartNightService.willInjectWeatherRecovery]), which the builder
/// (`SmartNightService.build`) calls at the actual emit sites. That shared
/// source of truth is what guarantees the preview never claims a watchdog
/// the emitted sequence won't contain (and vice-versa): tuning the cloud
/// threshold or the meridian boundary in the service automatically moves
/// the preview with it.
///
/// Returned in install order (meridian flip, then weather recovery).
List<SmartNightWatchdog> smartNightWatchdogsFor(SmartNightPlan plan) {
  final watchdogs = <SmartNightWatchdog>[];

  final transitingCount = plan.plannedTargets
      .where(SmartNightService.willInjectMeridianFlip)
      .length;

  if (transitingCount > 0) {
    final plural = transitingCount == 1 ? 'target crosses' : 'targets cross';
    watchdogs.add(SmartNightWatchdog(
      title: 'Meridian flip',
      detail: 'Runs in parallel and fires the moment a target reaches the '
          'meridian (by hour-angle, not list position). $transitingCount '
          '$plural the meridian inside their imaging window tonight; the '
          'mount flips, re-centers, refocuses, and resumes guiding '
          'automatically.',
    ));
  }

  if (SmartNightService.willInjectWeatherRecovery(plan.context)) {
    final cloudProb = plan.context.rainOrCloudProbability!;
    final leadMinutes = plan.context.cloudArrivalLeadTimeMinutes;
    watchdogs.add(SmartNightWatchdog(
      title: 'Weather recovery',
      detail: 'Runs in parallel as a weather-unsafe watchdog. If cloud or '
          'rain arrives (forecast '
          '${(cloudProb * 100).toStringAsFixed(0)}% within $leadMinutes min) '
          'it parks the mount and aborts the run, no matter which target is '
          'imaging.',
    ));
  }

  return watchdogs;
}

/// Renders the "Safety & Watchdogs" block in the plan preview.
///
/// Explains the parallel triggers the plan installs so users understand
/// they fire regardless of where a target sits in the list. Renders
/// nothing when the plan installs no watchdogs (keeps the preview clean
/// for short single-target plans that never cross the meridian and have
/// no weather risk). Distinct from the Warnings block — these are
/// informational descriptions of always-on safety automation, not
/// problems with the plan.
class SmartNightSafetyWatchdogsSection extends StatelessWidget {
  const SmartNightSafetyWatchdogsSection({
    super.key,
    required this.plan,
    required this.colors,
  });

  final SmartNightPlan plan;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    final watchdogs = smartNightWatchdogsFor(plan);
    if (watchdogs.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text(
          'Safety & Watchdogs',
          style:
              SkotiqTypography.labelStrong.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: 4),
        Text(
          'These run in parallel with the imaging branch and fire by '
          'condition, not by list position.',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            color: colors.textMuted,
          ),
        ),
        const SizedBox(height: 8),
        for (final w in watchdogs)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  LucideIcons.shieldAlert,
                  size: 14,
                  color: colors.warning,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '${w.title} — ',
                          style: SkotiqTypography.h6
                              .copyWith(color: colors.textSecondary),
                        ),
                        TextSpan(
                          text: w.detail,
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize12,
                            color: colors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
