import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import '../../../widgets/builtin_guider_config_form.dart';
import '../../settings/widgets/settings_widgets.dart';
import '../focuser_backlash/effective_backlash_readout.dart';
import '../utils/meridian_flip_pointer.dart';
import '../../../router/settings_sections.dart';
import '../../../router/app_routes.dart';

class EquipmentSettingsTab extends ConsumerWidget {
  const EquipmentSettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      // Skeleton grid mirrors the 4-card layout so the page doesn't reflow.
      loading: () => Padding(
        padding: const EdgeInsets.all(24),
        child: ResponsiveCardGrid(
          children: List.generate(4, (_) {
            return ShimmerLoading(
              child: Container(
                height: 180,
                decoration: BoxDecoration(
                  color: colors.well,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                ),
              ),
            );
          }),
        ),
      ),
      error: (e, _) => Center(child: Text('Error loading settings: ${userFacingError(e)}')),
      data: (settings) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        // No in-content title: both hosts (the desktop SkotiqDialog and
        // the phone AppBar) already render "Equipment Settings" directly
        // above this body, so repeating it cost a heading's worth of the
        // dialog's fixed 500 px height and said nothing new.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ResponsiveCardGrid(
              children: [
                _CameraSettingsCard(settings: settings),
                const _MountSettingsCard(),
                _FocuserSettingsCard(settings: settings),
                const _BuiltinGuiderSettingsCard(),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

typedef _Field<T> = SettingField<AppSettingsState, T>;

AppSettingsNotifier _settings(WidgetRef ref) =>
    ref.read(appSettingsProvider.notifier);

final _defaultGain = _Field<int>(
  label: 'Default gain',
  read: (s) => s.defaultGain,
  write: (ref, v) => _settings(ref).setDefaultGain(v),
  codec: IntCodec.of(AppSettingDefs.defaultGain),
);

final _defaultOffset = _Field<int>(
  label: 'Default offset',
  read: (s) => s.defaultOffset,
  write: (ref, v) => _settings(ref).setDefaultOffset(v),
  codec: IntCodec.of(AppSettingDefs.defaultOffset),
);

final _tempCompensation = _Field<bool>(
  label: 'Temperature compensation',
  read: (s) => s.tempCompensation,
  write: (ref, v) => _settings(ref).setTempCompensation(v),
);

final _tempCoefficient = _Field<double>(
  label: 'Temperature coefficient',
  read: (s) => s.tempCoefficient,
  write: (ref, v) => _settings(ref).setTempCoefficient(v),
  codec: NumberCodec.of(
    AppSettingDefs.tempCoefficient,
    decimals: 1,
    unit: 'steps/°C',
  ),
);

final _tempCompensationMinSteps = _Field<int>(
  label: 'Smallest compensation move',
  read: (s) => s.tempCompensationMinSteps,
  write: (ref, v) => _settings(ref).setTempCompensationMinSteps(v),
  codec: IntCodec.of(AppSettingDefs.tempCompensationMinSteps, unit: 'steps'),
);

final _backlashIn = _Field<int>(
  label: 'Backlash compensation',
  read: (s) => s.afBacklashIn,
  write: (ref, v) => _settings(ref).setAfBacklashIn(v),
  codec: IntCodec.of(AppSettingDefs.afBacklashIn, unit: 'steps'),
);

class _CameraSettingsCard extends StatelessWidget {
  final AppSettingsState settings;

  const _CameraSettingsCard({required this.settings});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Camera Settings',
              style: SkotiqTypography.sectionTitle
                  .copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: 16),
            _SettingRow(
              label: _defaultGain.label,
              child: SettingsField(field: _defaultGain, state: settings),
            ),
            const SizedBox(height: 12),
            _SettingRow(
              label: _defaultOffset.label,
              child: SettingsField(field: _defaultOffset, state: settings),
            ),
          ],
        ),
      ),
    );
  }
}

/// The mount holds no flip settings of its own: every run arms its meridian
/// flip from Settings > Sequencer > Meridian flip, so this card points there.
class _MountSettingsCard extends StatelessWidget {
  const _MountSettingsCard();

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mount',
              style: SkotiqTypography.sectionTitle
                  .copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: 12),
            Text(
              kMeridianFlipSettingsPointer,
              style:
                  SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: 12),
            SkotiqButton(
              label: 'Open meridian flip settings',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () {
                final router = GoRouter.of(context);
                Navigator.of(context).maybePop();
                router.goToSettings(SettingsSectionId.sequencer);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _FocuserSettingsCard extends ConsumerWidget {
  final AppSettingsState settings;

  const _FocuserSettingsCard({required this.settings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);

    // Gate the Temp Compensation row on whether the connected
    // focuser reports `tempCompAvailable`. The toggle is a Skotiq-side
    // controller (we re-issue moves based on a coefficient), but it
    // depends on the focuser publishing a temperature reading — drivers
    // without a probe will never provide one and the row would silently
    // do nothing. Use opacity-disable rather than visibility so the
    // setting remains discoverable; tooltip explains the reason.
    final focuserState = ref.watch(focuserStateProvider);
    final focuserCapsAsync = ref.watch(
        equipmentFocuserCapabilitiesProvider(focuserState.deviceId ?? ''));
    final tempCompAvailable = gateCapability<FocuserCapabilities>(
      focuserCapsAsync,
      (c) => c.tempCompAvailable,
      // While loading we keep the toggle live so existing setups don't
      // appear to lose their setting on every screen open.
      loadingDefault: true,
    );

    return SkotiqPanel(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Focuser Settings',
              style: SkotiqTypography.sectionTitle
                  .copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: 16),
            Tooltip(
              message: tempCompAvailable
                  ? ''
                  : 'Connected focuser does not report a temperature probe; '
                      'temp compensation cannot run.',
              child: _SettingRow(
                label: _tempCompensation.label,
                child: SettingsField(
                  field: _tempCompensation,
                  state: settings,
                  enabled: tempCompAvailable,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _SettingRow(
              label: _tempCoefficient.label,
              child: SettingsField(field: _tempCoefficient, state: settings),
            ),
            const SizedBox(height: 12),
            // A focuser probe reads in tenths of a degree, so without a floor
            // compensation stepped the focuser by one on every reading.
            _SettingRow(
              label: _tempCompensationMinSteps.label,
              subtitle: 'Waits until the correction owed reaches this size',
              child: KeyedSubtree(
                key: const ValueKey('temp-comp-min-steps'),
                child: SettingsField(
                  field: _tempCompensationMinSteps,
                  state: settings,
                ),
              ),
            ),
            const SizedBox(height: 12),
            _SettingRow(
              label: _backlashIn.label,
              subtitle: 'Steps the gear train loses when a move reverses '
                  'direction.',
              child: SettingsField(field: _backlashIn, state: settings),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            // Adopting a measured figure writes the setting; the field above
            // follows the stored value.
            EffectiveBacklashReadout(
              onUseMeasured: (steps) => _settings(ref).setAfBacklashIn(steps),
            ),
          ],
        ),
      ),
    );
  }
}

/// The built-in multi-star guider's settings. The guider runs inside Skotiq
/// on the imaging camera and pulse-guides the mount; its settings can be set
/// before it is connected.
class _BuiltinGuiderSettingsCard extends ConsumerWidget {
  const _BuiltinGuiderSettingsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final isConnected = ref.watch(isBuiltinGuiderProvider);
    return SkotiqPanel(
      key: const ValueKey('builtin-guider-settings-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Built-in Guider',
                    style: SkotiqTypography.sectionTitle
                        .copyWith(color: colors.textPrimary),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: SkotiqDecorations.tintedBadge(
                    isConnected ? colors.success : colors.textMuted,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                  ),
                  child: Text(
                    isConnected ? 'Active' : 'Standby',
                    style: SkotiqTypography.eyebrow.copyWith(
                      letterSpacing: 0,
                      color:
                          isConnected ? colors.success : colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Multi-star software guider that uses the imaging camera and mount '
              'pulse-guide. No second guide camera required. These values are '
              'sent to the guider together when you press Apply.',
              style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: 16),
            const BuiltinGuiderConfigForm(),
          ],
        ),
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  final String label;

  /// Optional one-line, plain-language explanation rendered under the label.
  final String? subtitle;
  final Widget child;

  const _SettingRow({required this.label, this.subtitle, required this.child});

  Widget _labelColumn(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stackFields = constraints.maxWidth < 220;
        if (stackFields) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _labelColumn(context),
              const SizedBox(height: 8),
              child,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              flex: 2,
              child: _labelColumn(context),
            ),
            const SizedBox(width: 12),
            Flexible(
              flex: 1,
              child: Align(
                alignment: Alignment.centerRight,
                child: child,
              ),
            ),
          ],
        );
      },
    );
  }
}
