part of '../weather_screen.dart';

/// What the safety status says, given the live verdict AND whether the
/// operator has weather safety switched on at all.
///
/// The provider reports [WeatherSafetyStatus.safe] when monitoring is OFF,
/// because there is no verdict to act on; rendering that as "Conditions safe
/// for imaging" would tell the operator the sky is being watched, so
/// monitoring-off has its own wording.
@visibleForTesting
String weatherSafetyStatusText({
  required WeatherSafetyStatus status,
  required bool monitoring,
  bool safetyMonitor = false,
  DateTime? snoozeUntil,
  DateTime? now,
}) {
  if (!monitoring) {
    // The standard Weather Unsafe trigger reads a connected safety monitor
    // whether or not weather safety is on.
    return safetyMonitor
        ? 'Weather safety is off. The safety monitor still stops a run when '
            'it reads unsafe.'
        : 'Weather safety is off, so conditions are not being checked.';
  }
  switch (status) {
    case WeatherSafetyStatus.safe:
      return 'Conditions safe for imaging';
    case WeatherSafetyStatus.unsafe:
      return 'Unsafe conditions detected';
    case WeatherSafetyStatus.snoozed:
      if (snoozeUntil != null) {
        final remaining = snoozeUntil.difference(now ?? DateTime.now());
        return 'Alerts snoozed for ${remaining.inMinutes} more minutes; '
            'safety unknown';
      }
      return 'Alerts snoozed';
  }
}

/// What weather safety does while no weather data arrives, from the fail
/// mode (`noDataFailModeResolution`). A null [failMode] is the shipped
/// fail-closed default while settings load.
@visibleForTesting
String weatherNoDataRuleText({
  required bool monitoring,
  required SafetyFailMode? failMode,
}) {
  if (!monitoring) {
    return 'Weather safety is off, so missing weather data never stops a run '
        'or parks the mount.';
  }
  switch (failMode ?? SafetyFailMode.failClosed) {
    case SafetyFailMode.failClosed:
      return 'With no weather data, safety treats the sky as unsafe: a run '
          'stops and the mount parks.';
    case SafetyFailMode.failOpen:
      return 'With no weather data, safety treats the sky as safe and '
          'imaging goes on.';
    case SafetyFailMode.warnOnly:
      return 'With no weather data, imaging goes on and Skotiq warns you.';
  }
}

/// How an auto-park / auto-resume policy is reported.
///
/// A toggle that is on but cannot fire (its prerequisites are off) is neither
/// "Enabled" nor "Disabled" — say which prerequisite holds it back instead of
/// showing a promise the rig will not keep.
@visibleForTesting
String weatherPolicyArmedLabel({
  required bool armed,
  required bool toggledOn,
  required bool monitoring,
}) {
  if (armed) return 'Enabled';
  if (!toggledOn) return 'Disabled';
  return monitoring ? 'Will not fire' : 'Off while safety is off';
}

/// The page header chip: the whole safety verdict in one or two words.
///
/// The long form lives in the conditions HUD; this is the glanceable version,
/// and it keeps the monitoring-off distinction —
/// "Not monitored" is not "Safe". With weather monitoring off, a connected
/// safety monitor still guards the run (the Weather Unsafe trigger reads it),
/// so its reading is the verdict; "Not monitored" only when nothing watches.
@visibleForTesting
String weatherSafetyChipLabel({
  required WeatherSafetyStatus status,
  required bool monitoring,
  SafetySourceReading monitor = SafetySourceReading.absent,
}) {
  if (!monitoring) {
    return switch (monitor) {
      SafetySourceReading.safe => 'Safe',
      SafetySourceReading.unsafe => 'Unsafe',
      _ => 'Not monitored',
    };
  }
  switch (status) {
    case WeatherSafetyStatus.safe:
      return 'Safe';
    case WeatherSafetyStatus.unsafe:
      return 'Unsafe';
    case WeatherSafetyStatus.snoozed:
      return 'Snoozed';
  }
}

/// The tone of the header chip. Monitoring-off is neutral, not green: nothing
/// was measured, so there is no status to colour.
@visibleForTesting
ChipTone weatherSafetyChipTone({
  required WeatherSafetyStatus status,
  required bool monitoring,
  SafetySourceReading monitor = SafetySourceReading.absent,
}) {
  if (!monitoring) {
    return switch (monitor) {
      SafetySourceReading.safe => ChipTone.success,
      SafetySourceReading.unsafe => ChipTone.error,
      _ => ChipTone.neutral,
    };
  }
  switch (status) {
    case WeatherSafetyStatus.safe:
      return ChipTone.success;
    case WeatherSafetyStatus.unsafe:
      return ChipTone.error;
    case WeatherSafetyStatus.snoozed:
      return ChipTone.warning;
  }
}

/// The safety block inside the conditions HUD: the sentence the chip cannot
/// fit, and the snooze controls when there is something to snooze.
class _SafetyDisclosure extends ConsumerWidget {
  const _SafetyDisclosure();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final safetyState = ref.watch(weatherSafetyProvider);
    final status = safetyState.status;
    final monitoring = safetyState.monitoringEnabled;

    // Safe + monitoring is the ordinary case and the chip already says so;
    // repeating it here would be the app explaining itself twice (02 rule 5).
    final needsSentence = !monitoring || status != WeatherSafetyStatus.safe;
    if (!needsSentence) return const SizedBox.shrink();

    final tone = !monitoring
        ? colors.textMuted
        : status == WeatherSafetyStatus.snoozed
            ? colors.warning
            : colors.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              !monitoring
                  ? SkotiqIcons.shieldOff
                  : status == WeatherSafetyStatus.unsafe
                      ? SkotiqIcons.shieldAlert
                      : SkotiqIcons.shieldOk,
              size: SkotiqTokens.iconSm,
              color: tone,
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                weatherSafetyStatusText(
                  status: status,
                  monitoring: monitoring,
                  safetyMonitor: safetyState.safetyMonitorReading !=
                      SafetySourceReading.absent,
                  snoozeUntil: safetyState.snoozeUntil,
                ),
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
        if (status == WeatherSafetyStatus.snoozed) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          SkotiqButton(
            label: 'Cancel snooze',
            icon: SkotiqIcons.notificationsOff,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () =>
                ref.read(weatherSafetyProvider.notifier).cancelSnooze(),
          ),
        ] else if (status == WeatherSafetyStatus.unsafe) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          // Wrap, not Row: two buttons plus their labels do not fit a 300 px
          // HUD at every text scale, and a clipped snooze is a control the
          // operator cannot reach when the sky is closing in.
          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              SkotiqButton(
                label: 'Snooze 15 min',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: () => ref
                    .read(weatherSafetyProvider.notifier)
                    .snooze(const Duration(minutes: 15)),
              ),
              SkotiqButton(
                label: '30 min',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: () => ref
                    .read(weatherSafetyProvider.notifier)
                    .snooze(const Duration(minutes: 30)),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
