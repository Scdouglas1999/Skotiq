// "Schedule" tab: the seven-night forecast strip pinned above the dynamic
// target-queue scheduler. The former "This Week" + "Target Queue" tabs are
// unified here — the forecast answers *which* upcoming nights to run the queue,
// the scheduler runs it. The strip mounts only when the forecast actually has
// rankable nights, so an empty/unavailable forecast never steals vertical space
// from the scheduler (which is the tab's primary surface).
part of '../planner_screen.dart';

class _ScheduleTab extends ConsumerWidget {
  const _ScheduleTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final forecast = ref.watch(weekForecastProvider).valueOrNull;
    final showStrip =
        forecast != null && forecast.available && forecast.nights.isNotEmpty;

    return Column(
      children: [
        // The live scheduler's own pick, above the queue it comes from. It
        // moved here from Tonight (06 §Plan) so the autopilot is described
        // once, beside the list it runs.
        const _AutopilotPreviewBanner(),
        if (showStrip)
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.border)),
            ),
            child: const WeekForecastStrip(),
          ),
        const Expanded(child: SchedulerTabContent()),
      ],
    );
  }
}
