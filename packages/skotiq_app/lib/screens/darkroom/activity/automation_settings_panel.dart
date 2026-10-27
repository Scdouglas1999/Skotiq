import '../processing_options_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/user_facing_error.dart';
import '../../session_review/auto_integration_service.dart';
import '../../settings/delivery_settings.dart';
import '../../settings/settings_screen.dart' show SettingsSectionRequest;
import 'activity_panel.dart';

/// Open the Settings section [sectionKey] names.
void _openSettings(BuildContext context, String sectionKey) {
  SettingsSectionRequest.raise(sectionKey);
  context.go('/settings?section=$sectionKey');
}

/// What Delivery holds for the night right now, in one sentence, from the
/// same verdict the Delivery page states for each destination.
String deliveryDependencyState(AsyncValue<DeliveryDestinations> destinations) {
  if (destinations.hasError) {
    return 'The destinations could not be read '
        '(${userFacingError(destinations.error)}).';
  }
  final read = destinations.valueOrNull;
  if (read == null) return 'Reading the destinations.';
  final configured = read.views.length + read.unreadable.length;
  if (configured == 0) {
    return 'No destination is set up, so the files stay on this computer.';
  }
  final blocked =
      read.views.where((view) => _cannotReceive(view.status.kind)).length +
          read.unreadable.length;
  final count =
      '$configured destination${configured == 1 ? ' is' : 's are'} set up';
  if (blocked == 0) return '$count and ready.';
  if (configured == 1) return '$count and it cannot be delivered to now.';
  return '$count and $blocked cannot be delivered to now.';
}

bool _cannotReceive(DeliveryStatusKind kind) =>
    kind == DeliveryStatusKind.off || kind == DeliveryStatusKind.incomplete;

/// What the notification gates the morning message passes are set to.
String notificationDependencyState(AsyncValue<AppSettingsState> settings) {
  if (settings.hasError) {
    return 'The notification settings could not be read '
        '(${userFacingError(settings.error)}).';
  }
  final read = settings.valueOrNull;
  if (read == null) return 'Reading the notification settings.';
  if (!read.notificationsEnabled) {
    return 'Notifications are off in Settings, so no message would be sent.';
  }
  if (!read.notifyOnSequenceComplete) {
    return 'The sequence-complete alert is off in Settings, so no message '
        'would be sent.';
  }
  return 'It goes out through your notification settings.';
}

/// The night-end automation, every step in the order it runs, each with its
/// own switch: take darks and bias, build masters for every imaged target
/// from all its nights, the minimum field to accept, deliver, and the morning
/// message.
class AutomationSettingsPanel extends ConsumerStatefulWidget {
  const AutomationSettingsPanel({super.key});

  @override
  ConsumerState<AutomationSettingsPanel> createState() =>
      _AutomationSettingsPanelState();
}

class _AutomationSettingsPanelState
    extends ConsumerState<AutomationSettingsPanel> {
  String? _error;
  double? _field;

  Future<void> _save(
      Future<void> Function(NightEndAutomationActions) write) async {
    setState(() => _error = null);
    try {
      await write(ref.read(nightEndAutomationActionsProvider));
      // The build switch is also read through the older provider by the
      // pages that still show it.
      ref.invalidate(autoIntegrationEnabledProvider);
    } catch (e) {
      if (mounted) {
        setState(
            () => _error = 'The setting was not saved: ${userFacingError(e)}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final settings = ref.watch(nightEndAutomationSettingsProvider);
    final value = settings.valueOrNull;
    final loaded = value != null;
    final s = value ?? const NightEndAutomationSettings();
    final field = _field ?? s.minRetainedArea;
    return ActivityPanel(
      key: const ValueKey('darkroom_activity_automation'),
      title: 'Night-end automation',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'When the night ends (dawn, an obstruction, or the plan '
            'completes), these steps run in order with nobody at the '
            'computer.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          if (settings.hasError)
            Padding(
              padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
              child: Text(
                'The automation settings could not be read: '
                '${userFacingError(settings.error)}',
                style: SkotiqTypography.bodySm.copyWith(color: colors.error),
              ),
            ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _Step(
            number: 1,
            switchKey: const ValueKey('night_end_calibrate'),
            title: 'Take darks and bias',
            body: 'Matched to the night\'s lights, through the dark slot or '
                'behind a cap, then built into the library.',
            value: s.calibrate,
            enabled: loaded,
            onChanged: (on) => _save((a) => a.setCalibrate(on)),
            link: (
              'Calibration options',
              () => _openSettings(context, 'end-of-night-calibration'),
            ),
          ),
          _Step(
            number: 2,
            switchKey: const ValueKey('night_end_build'),
            title: 'Build masters',
            body: 'For every target imaged that night, from all of its nights. '
                'New nights fold into the target\'s existing build; filters '
                'with no new subs are kept as they are. First builds the flat '
                'batches you selected for Night end in Calibration.',
            value: s.build,
            enabled: loaded,
            onChanged: (on) => _save((a) => a.setBuild(on)),
            footer: Column(children: [
              const ProcessingDefaultsPanel(),
              Row(children: [
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('Allow incomplete calibration',
                          style: SkotiqTypography.bodyStrong
                              .copyWith(color: colors.textPrimary)),
                      Text(
                          'Off by default: wait for matching flats and exact-exposure darks. '
                          'Turn on to permit omitted calibration and scaled darks; image quality may suffer.',
                          style: SkotiqTypography.bodySm
                              .copyWith(color: colors.textSecondary)),
                    ])),
                SkotiqSwitch(
                  key: const ValueKey('night_end_incomplete_calibration'),
                  value: s.allowIncompleteCalibration,
                  enabled: loaded && s.build,
                  onChanged: (on) =>
                      _save((a) => a.setAllowIncompleteCalibration(on)),
                ),
              ]),
              _FieldSlider(
                value: field,
                enabled: loaded && s.build,
                onChanged: (v) => setState(() => _field = v),
                onChangeEnd: (v) async {
                  await _save((a) => a.setMinRetainedArea(v));
                  if (mounted) setState(() => _field = null);
                },
              ),
            ]),
          ),
          _Step(
            number: 3,
            switchKey: const ValueKey('night_end_deliver'),
            title: 'Deliver',
            body: 'Copy the masters, previews and the build report to your '
                'delivery destinations. '
                '${deliveryDependencyState(ref.watch(deliveryDestinationsProvider))}',
            value: s.deliver,
            enabled: loaded && s.build,
            disabledReason: s.build ? null : 'Needs Build masters.',
            onChanged: (on) => _save((a) => a.setDeliver(on)),
            link: ('Destinations', () => _openSettings(context, 'delivery')),
          ),
          _Step(
            number: 4,
            switchKey: const ValueKey('night_end_message'),
            title: 'Morning message',
            body: 'One notification when it is all done, opening the target or '
                'the framing check that waits for you. '
                '${notificationDependencyState(ref.watch(appSettingsProvider))}',
            value: s.morningMessage,
            enabled: loaded && s.anyOn,
            disabledReason: s.anyOn ? null : 'Nothing runs to report on.',
            onChanged: (on) => _save((a) => a.setMorningMessage(on)),
            link: (
              'Notifications',
              () => _openSettings(context, 'notifications'),
            ),
            last: true,
          ),
          if (_error != null)
            Text(
              _error!,
              style: SkotiqTypography.bodySm.copyWith(color: colors.error),
            ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.switchKey,
    required this.title,
    required this.body,
    required this.value,
    required this.enabled,
    required this.onChanged,
    this.disabledReason,
    this.link,
    this.footer,
    this.last = false,
  });

  final int number;
  final Key switchKey;
  final String title;
  final String body;
  final bool value;
  final bool enabled;
  final String? disabledReason;
  final ValueChanged<bool> onChanged;
  final (String, VoidCallback)? link;
  final Widget? footer;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final dim = !enabled && disabledReason != null;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceMd),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: SkotiqTokens.spaceXl,
            child: Text(
              '$number',
              style: SkotiqTypography.monoSm.copyWith(color: colors.textMuted),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: SkotiqTypography.bodyStrong.copyWith(
                          color: dim ? colors.textMuted : colors.textPrimary,
                        ),
                      ),
                    ),
                    Semantics(
                      label: title,
                      child: SkotiqSwitch(
                        key: switchKey,
                        value: value,
                        enabled: enabled,
                        onChanged: onChanged,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  dim ? '${disabledReason!} $body' : body,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: dim ? colors.textMuted : colors.textSecondary,
                  ),
                ),
                if (footer != null) footer!,
                if (link != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        top: SkotiqTokens.spaceSm,
                      ),
                      child: SkotiqButton(
                        label: link!.$1,
                        icon: SkotiqIcons.arrowRight,
                        variant: ButtonVariant.ghost,
                        size: ButtonSize.small,
                        onPressed: link!.$2,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The smallest shared field a build accepts on its own.
class _FieldSlider extends StatelessWidget {
  const _FieldSlider({
    required this.value,
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final double value;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final percent = '${(value * 100).round()}%';
    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Minimum field to accept',
                  style: SkotiqTypography.label.copyWith(
                    color: enabled ? colors.textPrimary : colors.textMuted,
                  ),
                ),
              ),
              Text(
                percent,
                key: const ValueKey('night_end_min_field_value'),
                style: SkotiqTypography.monoSm.copyWith(
                  color: enabled ? colors.textPrimary : colors.textMuted,
                ),
              ),
            ],
          ),
          Semantics(
            label: 'Minimum field to accept',
            value: percent,
            child: SkotiqSlider(
              key: const ValueKey('night_end_min_field'),
              value: value.clamp(
                NightEndAutomationSettings.minField,
                NightEndAutomationSettings.maxField,
              ),
              min: NightEndAutomationSettings.minField,
              max: NightEndAutomationSettings.maxField,
              divisions: 14,
              onChanged: enabled ? onChanged : null,
              onChangeEnd: onChangeEnd,
            ),
          ),
          Text(
            'A build whose shared field keeps less than this waits for you '
            'at the framing check instead of building.',
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}
