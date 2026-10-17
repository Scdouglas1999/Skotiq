part of '../weather_screen.dart';

/// What the safety status says, given the live verdict AND whether the
/// operator has weather safety switched on at all.
///
/// Audit 2026-07-29: the provider reports [WeatherSafetyStatus.safe] when
/// monitoring is OFF, because there is no verdict to act on. Rendering that as
/// "Conditions safe for imaging" told the operator the sky was being watched
/// when nothing was checking it, so monitoring-off has its own wording.
@visibleForTesting
String weatherSafetyStatusText({
  required WeatherSafetyStatus status,
  required bool monitoring,
  DateTime? snoozeUntil,
  DateTime? now,
}) {
  if (!monitoring) {
    return 'Not monitoring — weather safety is off, conditions are not '
        'being checked';
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

/// How an auto-park / auto-resume policy is reported.
///
/// A toggle that is on but cannot fire (its prerequisites are off) is neither
/// "Enabled" nor "Disabled" — say so instead of showing a green promise the rig
/// will not keep.
@visibleForTesting
String weatherPolicyArmedLabel({
  required bool armed,
  required bool toggledOn,
}) {
  if (armed) return 'Enabled';
  return toggledOn ? 'On, not armed' : 'Disabled';
}

/// The page header chip: the whole safety verdict in one or two words.
///
/// The long form lives in the conditions HUD; this is the glanceable version,
/// and it keeps the monitoring-off distinction the 2026-07-29 audit demanded —
/// "Not monitored" is not "Safe".
@visibleForTesting
String weatherSafetyChipLabel({
  required WeatherSafetyStatus status,
  required bool monitoring,
}) {
  if (!monitoring) return 'Not monitored';
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
}) {
  if (!monitoring) return ChipTone.neutral;
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
