// Settings and controls for the end-of-night calibration step: darks and bias
// taken automatically when the night's imaging ends, built into masters in the
// dark library.
//
// The settings live in the imaging host's own database and the step runs on
// the host, so a remote client is told where to change them instead of being
// offered switches that would govern nothing.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/user_facing_error.dart';
import 'settings_widgets.dart';

final endOfNightSettingsProvider = FutureProvider.autoDispose<EonSettings>(
  (ref) => EonSettings.load(ref.watch(settingsDaoProvider)),
);

class EndOfNightCalibrationSettings extends ConsumerStatefulWidget {
  const EndOfNightCalibrationSettings({super.key, this.isMobile = false});

  final bool isMobile;

  static const title = 'End-of-night calibration';
  static const description =
      'Darks and bias for every light setting used tonight, taken '
      'automatically when imaging ends and built into masters in the dark '
      'library.';

  @override
  ConsumerState<EndOfNightCalibrationSettings> createState() =>
      _EndOfNightCalibrationSettingsState();
}

class _EndOfNightCalibrationSettingsState
    extends ConsumerState<EndOfNightCalibrationSettings> {
  final _darkCount = TextEditingController();
  final _biasCount = TextEditingController();
  final _capWait = TextEditingController();

  @override
  void dispose() {
    _darkCount.dispose();
    _biasCount.dispose();
    _capWait.dispose();
    super.dispose();
  }

  Future<void> _save(EonSettings updated) async {
    try {
      await ref.read(settingsDaoProvider).setSettings(updated.toStorage());
    } catch (e) {
      if (mounted) {
        SkotiqToastHelper.show(
          context: context,
          message: userFacingError(e),
          severity: SkotiqAlertSeverity.error,
        );
      }
    }
    ref.invalidate(endOfNightSettingsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = widget.isMobile;
    if (ref.watch(isRemoteClientProvider)) {
      return SettingsPage(
        title: EndOfNightCalibrationSettings.title,
        description: EndOfNightCalibrationSettings.description,
        isMobile: isMobile,
        children: const [
          EmptyState(
            icon: LucideIcons.server,
            title: 'End-of-night calibration runs on the imaging host',
            body: 'Its settings live in the imaging host\'s own database and '
                'the darks are taken there. Open Settings on the host to '
                'change them.',
          ),
        ],
      );
    }
    final settings = ref.watch(endOfNightSettingsProvider);
    return switch (settings) {
      AsyncData(:final value) => _page(value, isMobile),
      AsyncError(:final error) => SettingsErrorState(
          error: error,
          isMobile: isMobile,
          onRetry: () => ref.invalidate(endOfNightSettingsProvider),
        ),
      _ => SettingsLoadingState(isMobile: isMobile),
    };
  }

  Widget _page(EonSettings s, bool isMobile) {
    return SettingsPage(
      title: EndOfNightCalibrationSettings.title,
      description: EndOfNightCalibrationSettings.description,
      isMobile: isMobile,
      children: [
        const _EndOfNightStatusCard(),
        SettingsSection(
          title: 'When imaging ends',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.moonStar,
              title: 'Take darks and bias when imaging ends',
              subtitle:
                  'Starts when a run that took light frames completes, is '
                  'ended by dawn, or the scheduler ends the night. An '
                  'operator stop does not start it.',
              trailing: SettingsSwitch(
                value: s.enabled,
                onChanged: (v) => _save(s.copyWith(enabled: v)),
              ),
              isMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.home,
              title: 'Mount before the darks',
              subtitle: 'Guiding is stopped first. A mount the night already '
                  'parked is left parked.',
              trailing: SettingsDropdown(
                value: s.mountAction.name,
                items: const ['home', 'park', 'leave'],
                itemLabels: const ['Send home', 'Park', 'Leave it'],
                isMobile: isMobile,
                onChanged: (v) =>
                    _save(s.copyWith(mountAction: EonMountAction.parse(v))),
              ),
              isMobile: isMobile,
              stackOnMobile: true,
            ),
            SettingRow(
              icon: LucideIcons.thermometerSnowflake,
              title: 'Warm the camera up afterwards',
              subtitle: 'Raises the set-point gradually once the frames are '
                  'taken, then switches the cooler off.',
              trailing: SettingsSwitch(
                value: s.warmUp,
                onChanged: (v) => _save(s.copyWith(warmUp: v)),
              ),
              isLast: true,
              isMobile: isMobile,
            ),
          ],
        ),
        SettingsSection(
          title: 'Frames',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.layers,
              title: 'Darks per light setting',
              subtitle: 'One set for each exposure, gain, offset, binning and '
                  'set-point used tonight, at that set-point.',
              trailing: SettingsNumberInput(
                controller: _darkCount,
                authoritativeValue: s.darkCount.toDouble(),
                authorityKey: 'eon',
                suffix: '',
                min: EonSettings.minCount.toDouble(),
                max: EonSettings.maxCount.toDouble(),
                decimals: 0,
                isMobile: isMobile,
                onChanged: (v) => _save(s.copyWith(darkCount: v.round())),
              ),
              isMobile: isMobile,
            ),
            SettingRow(
              icon: LucideIcons.layers,
              title: 'Bias frames',
              subtitle: 'One set for each gain, offset and binning.',
              trailing: SettingsNumberInput(
                controller: _biasCount,
                authoritativeValue: s.biasCount.toDouble(),
                authorityKey: 'eon',
                suffix: '',
                min: EonSettings.minCount.toDouble(),
                max: EonSettings.maxCount.toDouble(),
                decimals: 0,
                isMobile: isMobile,
                onChanged: (v) => _save(s.copyWith(biasCount: v.round())),
              ),
              isLast: true,
              isMobile: isMobile,
            ),
          ],
        ),
        SettingsSection(
          title: 'Blocking the light',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.circleSlash,
              title: 'Without a dark slot in the filter wheel',
              subtitle: 'The frames are taken through a wheel slot named Dark, '
                  'Blank, Opaque, Closed, Shutter, Cap or Blocked. Without '
                  'one, Skotiq can ask you to cap the telescope or skip the '
                  'darks and bias.',
              trailing: SettingsDropdown(
                value: s.noDarkSlot.wireValue,
                items: const ['ask', 'skip'],
                itemLabels: const ['Ask me to cap it', 'Skip them'],
                isMobile: isMobile,
                onChanged: (v) => _save(
                  s.copyWith(noDarkSlot: EonNoDarkSlotPolicy.parse(v)),
                ),
              ),
              isMobile: isMobile,
              stackOnMobile: true,
            ),
            SettingRow(
              icon: LucideIcons.timer,
              title: 'Wait for the cap',
              subtitle: 'How long to wait for you to confirm the telescope is '
                  'capped before skipping the darks and bias.',
              trailing: SettingsNumberInput(
                controller: _capWait,
                authoritativeValue: s.capWaitMinutes.toDouble(),
                authorityKey: 'eon',
                suffix: 'min',
                min: 1,
                max: 240,
                decimals: 0,
                isMobile: isMobile,
                onChanged: (v) => _save(s.copyWith(capWaitMinutes: v.round())),
              ),
              isLast: true,
              isMobile: isMobile,
            ),
          ],
        ),
      ],
    );
  }
}

/// What the step is doing now, or what it did last, with its controls.
class _EndOfNightStatusCard extends ConsumerWidget {
  const _EndOfNightStatusCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final status = ref.watch(endOfNightCalibrationProvider);
    final service = ref.read(endOfNightCalibrationProvider.notifier);
    final canStart = ref.watch(sequenceExecutionStateProvider).canStart;
    final report = status.report;
    final (pill, label) = switch (status.phase) {
      EonPhase.idle => (StatusPillStatus.inactive, 'Not run yet'),
      EonPhase.preparing => (StatusPillStatus.active, 'Preparing'),
      EonPhase.waitingForCap => (StatusPillStatus.warning, 'Waiting for cap'),
      EonPhase.capturing => (StatusPillStatus.active, 'Taking frames'),
      EonPhase.buildingMasters => (StatusPillStatus.active, 'Building masters'),
      EonPhase.finished => (StatusPillStatus.success, 'Finished'),
      EonPhase.skipped => (StatusPillStatus.warning, 'Skipped'),
      EonPhase.failed => (StatusPillStatus.error, 'Failed'),
      EonPhase.cancelled => (StatusPillStatus.inactive, 'Stopped'),
    };
    final detail = report?.summary.isNotEmpty == true
        ? report!.summary
        : status.message ??
            'Run it now to take darks and bias for tonight\'s lights.';
    return SkotiqCard(
      child: Padding(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceSm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusPill(
                  icon: LucideIcons.moonStar,
                  label: 'Calibration',
                  value: label,
                  status: pill,
                ),
                if (report != null && report.masters.isNotEmpty)
                  Text(
                    '${report.masters.where((m) => m.built).length} of '
                    '${report.masters.length} masters built',
                    style: SkotiqTypography.labelSm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            Text(
              detail,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
            if (report != null && report.problems.isNotEmpty) ...[
              const SizedBox(height: SkotiqTokens.spaceSm),
              for (final problem in report.problems)
                Padding(
                  padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
                  child: Text(
                    problem,
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.warning,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: SkotiqTokens.spaceMd),
            Wrap(
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceSm,
              children: [
                if (status.phase == EonPhase.waitingForCap)
                  SkotiqButton(
                    label: 'The telescope is capped',
                    icon: LucideIcons.check,
                    size: ButtonSize.small,
                    onPressed: service.confirmCapped,
                  ),
                if (status.phase.isActive)
                  SkotiqButton(
                    label: 'Stop',
                    icon: LucideIcons.square,
                    variant: ButtonVariant.secondary,
                    size: ButtonSize.small,
                    onPressed: service.cancel,
                  )
                else
                  SkotiqButton(
                    label: 'Take darks and bias now',
                    icon: LucideIcons.play,
                    variant: ButtonVariant.secondary,
                    size: ButtonSize.small,
                    onPressed: canStart
                        ? () => ref
                            .read(endOfNightCalibrationCoordinatorProvider)
                            .runNow()
                        : null,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
