import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import 'safety_fail_mode_labels.dart';
import 'settings_widgets.dart';

class WeatherSafetySettings extends ConsumerStatefulWidget {
  final bool isMobile;

  const WeatherSafetySettings({
    super.key,
    this.isMobile = false,
  });

  @override
  ConsumerState<WeatherSafetySettings> createState() =>
      _WeatherSafetySettingsState();
}

class _WeatherSafetySettingsState extends ConsumerState<WeatherSafetySettings> {
  final _humidityController = TextEditingController();
  final _windController = TextEditingController();
  final _cloudController = TextEditingController();
  final _distanceController = TextEditingController();
  final _leadTimeController = TextEditingController();
  WeatherSettings? _controllerSettings;

  @override
  void dispose() {
    _humidityController.dispose();
    _windController.dispose();
    _cloudController.dispose();
    _distanceController.dispose();
    _leadTimeController.dispose();
    super.dispose();
  }

  void _syncControllers(WeatherSettings settings) {
    if (_controllerSettings == settings) return;
    _humidityController.text = settings.maxHumidityPercent.toStringAsFixed(0);
    _windController.text = settings.maxWindSpeedKph.toStringAsFixed(0);
    _cloudController.text = settings.maxCloudCoverPercent.toStringAsFixed(0);
    _distanceController.text = settings.triggerDistanceKm.toStringAsFixed(0);
    _leadTimeController.text = settings.leadTimeMinutes.toString();
    _controllerSettings = settings;
  }

  Future<void> _updateSettings({
    double? triggerDistanceKm,
    int? leadTimeMinutes,
    bool? weatherSafetyEnabled,
    double? maxHumidityPercent,
    double? maxWindSpeedKph,
    double? maxCloudCoverPercent,
    bool? autoParkEnabled,
    bool? autoResumeEnabled,
  }) {
    return ref.read(weatherSettingsActionsProvider).updateSettings(
          triggerDistanceKm: triggerDistanceKm,
          leadTimeMinutes: leadTimeMinutes,
          weatherSafetyEnabled: weatherSafetyEnabled,
          maxHumidityPercent: maxHumidityPercent,
          maxWindSpeedKph: maxWindSpeedKph,
          maxCloudCoverPercent: maxCloudCoverPercent,
          autoParkEnabled: autoParkEnabled,
          autoResumeEnabled: autoResumeEnabled,
        );
  }

  /// Append the master-switch prerequisite to a row description when weather
  /// safety is off, so a row showing "on" cannot read as active protection.
  static String _withPrerequisite(String description, bool masterEnabled) {
    if (masterEnabled) return description;
    return '$description — inactive until "Enable weather safety" is on';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settingsAsync = ref.watch(weatherSettingsDataProvider);
    final settings = settingsAsync.valueOrNull;
    // Auto-park is gated by the Sequencer "Park on unsafe weather" policy as
    // well as by this page's toggle, and both are gated by the master switch.
    // Show the composed truth and disclose the prerequisite instead of letting
    // this page claim protection another page has switched off.
    final appSettings = ref.watch(appSettingsProvider).valueOrNull;
    // While app settings are still loading fall back to the weather-side toggle
    // rather than defaulting the composed value to false: flashing "off" for a
    // setting that is on is its own small lie.
    final parkPolicyEnabled = appSettings != null
        ? appSettings.parkOnUnsafeWeather
        : settings?.autoParkEnabled == true;

    if (settings == null) {
      return SettingsPage(
        title: l10n.text('weatherSafetyTitle'),
        description: l10n.text('weatherSafetyDescription'),
        isMobile: widget.isMobile,
        hideHeader: widget.isMobile,
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: settingsAsync.hasError
                ? Column(
                    children: [
                      const Text('Could not load weather safety settings.'),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () =>
                            ref.invalidate(weatherSettingsDataProvider),
                        child: const Text('Retry'),
                      ),
                    ],
                  )
                : const Center(
                    child:
                        SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
          ),
        ],
      );
    }
    _syncControllers(settings);
    final policy = ref.watch(weatherDecisionPolicyProvider).valueOrNull;

    return SettingsPage(
      title: l10n.text('weatherSafetyTitle'),
      description: l10n.text('weatherSafetyDescription'),
      isMobile: widget.isMobile,
      hideHeader: widget.isMobile,
      children: [
        SettingsSection(
          title: l10n.text('weatherSafetyActions'),
          isMobile: widget.isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.shield,
              title: l10n.text('weatherSafetyEnable'),
              subtitle: l10n.text('weatherSafetyEnableDesc'),
              trailing: SettingsSwitch(
                value: settings.weatherSafetyEnabled,
                onChanged: (value) =>
                    _updateSettings(weatherSafetyEnabled: value),
              ),
              isMobile: widget.isMobile,
            ),
            WeatherSafetyPolicyRows(
              masterEnabled: settings.weatherSafetyEnabled,
              isMobile: widget.isMobile,
            ),
            SettingRow(
              icon: LucideIcons.mapPin,
              title: l10n.text('weatherSafetyAutoPark'),
              subtitle: _withPrerequisite(
                l10n.text('weatherSafetyAutoParkDesc'),
                settings.weatherSafetyEnabled,
              ),
              trailing: SettingsSwitch(
                // One logical setting, two stores: writing it here also writes
                // the Sequencer "Park on unsafe weather" policy, so the two
                // pages cannot disagree about whether auto-park is on.
                value: settings.autoParkEnabled && parkPolicyEnabled,
                onChanged: (value) => ref
                    .read(weatherSettingsActionsProvider)
                    .setAutoParkOnUnsafe(value),
              ),
              isMobile: widget.isMobile,
            ),
            SettingRow(
              icon: LucideIcons.cloud,
              title: l10n.text('weatherSafetyForecastHolds'),
              subtitle: _withPrerequisite(
                l10n.text('weatherSafetyForecastHoldsDesc'),
                settings.weatherSafetyEnabled,
              ),
              trailing: SettingsSwitch(
                value: policy?.forecastHoldsRun ?? false,
                enabled: policy != null,
                onChanged: (value) => ref
                    .read(weatherSettingsActionsProvider)
                    .setDecisionPolicy(forecastHoldsRun: value),
              ),
              isMobile: widget.isMobile,
            ),
            SettingRow(
              icon: LucideIcons.sparkles,
              title: l10n.text('weatherSafetyStarEvidence'),
              subtitle: _withPrerequisite(
                l10n.text('weatherSafetyStarEvidenceDesc'),
                settings.weatherSafetyEnabled,
              ),
              trailing: SettingsSwitch(
                value: policy?.starEvidenceOverridesForecast ?? true,
                enabled: policy != null,
                onChanged: (value) => ref
                    .read(weatherSettingsActionsProvider)
                    .setDecisionPolicy(starEvidenceOverridesForecast: value),
              ),
              isMobile: widget.isMobile,
            ),
            SettingRow(
              icon: LucideIcons.play,
              title: l10n.text('weatherSafetyAutoResume'),
              subtitle: _withPrerequisite(
                l10n.text('weatherSafetyAutoResumeDesc'),
                settings.weatherSafetyEnabled,
              ),
              trailing: SettingsSwitch(
                value: settings.autoResumeEnabled,
                onChanged: (value) => _updateSettings(autoResumeEnabled: value),
              ),
              isMobile: widget.isMobile,
              isLast: true,
            ),
          ],
        ),
        SettingsSection(
          title: l10n.text('weatherSafetyHardware'),
          isMobile: widget.isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.droplets,
              title: l10n.text('weatherSafetyMaxHumidity'),
              subtitle: l10n.text('weatherSafetyMaxHumidityDesc'),
              trailing: SettingsNumberInput(
                controller: _humidityController,
                suffix: '%',
                min: 0,
                max: 100,
                decimals: 0,
                onChanged: (value) =>
                    _updateSettings(maxHumidityPercent: value),
              ),
              isMobile: widget.isMobile,
            ),
            SettingRow(
              icon: LucideIcons.wind,
              title: l10n.text('weatherSafetyMaxWind'),
              subtitle: l10n.text('weatherSafetyMaxWindDesc'),
              trailing: SettingsNumberInput(
                controller: _windController,
                suffix: 'km/h',
                min: 0,
                max: 150,
                decimals: 0,
                onChanged: (value) => _updateSettings(maxWindSpeedKph: value),
              ),
              isMobile: widget.isMobile,
            ),
            SettingRow(
              icon: LucideIcons.cloud,
              title: l10n.text('weatherSafetyMaxCloud'),
              subtitle: l10n.text('weatherSafetyMaxCloudDesc'),
              trailing: SettingsNumberInput(
                controller: _cloudController,
                suffix: '%',
                min: 0,
                max: 100,
                decimals: 0,
                onChanged: (value) =>
                    _updateSettings(maxCloudCoverPercent: value),
              ),
              isMobile: widget.isMobile,
              isLast: true,
            ),
          ],
        ),
        SettingsSection(
          title: l10n.text('weatherSafetyAlertTiming'),
          isMobile: widget.isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.radar,
              title: l10n.text('weatherSafetyAlertDistance'),
              subtitle: l10n.text('weatherSafetyAlertDistanceDesc'),
              trailing: SettingsNumberInput(
                controller: _distanceController,
                suffix: 'km',
                min: 1,
                max: 500,
                decimals: 0,
                onChanged: (value) => _updateSettings(triggerDistanceKm: value),
              ),
              isMobile: widget.isMobile,
            ),
            SettingRow(
              icon: LucideIcons.timerReset,
              title: l10n.text('weatherSafetyLeadTime'),
              subtitle: l10n.text('weatherSafetyLeadTimeDesc'),
              trailing: SettingsNumberInput(
                controller: _leadTimeController,
                suffix: 'min',
                min: 1,
                max: 180,
                decimals: 0,
                onChanged: (value) =>
                    _updateSettings(leadTimeMinutes: value.toInt()),
              ),
              isMobile: widget.isMobile,
              isLast: true,
            ),
          ],
        ),
      ],
    );
  }
}

/// The two rows that state what weather safety will actually do: which safety
/// sources are attached, and the fail mode that decides what happens when none
/// is. Both live on the page that owns the master switch — before this the
/// operator could arm weather safety on a sensorless rig with the page showing
/// neither fact, and only meet the consequence when a run refused to start.
///
/// Its own widget because [WeatherSafetySettings] as a whole cannot be pumped
/// in flutter_test (it hangs the isolate, at HEAD as well as here), and copy
/// this load-bearing has to be asserted against rendered widgets.
class WeatherSafetyPolicyRows extends ConsumerWidget {
  /// Weather safety's master switch. When off, nothing here is in force and the
  /// rows say so rather than reading as active protection.
  final bool masterEnabled;
  final bool isMobile;

  const WeatherSafetyPolicyRows({
    super.key,
    required this.masterEnabled,
    this.isMobile = false,
  });

  /// What the safety sources currently read, and — when there are none — what
  /// the stored fail mode does about it.
  ///
  /// The readings come from [weatherSafetySourceReadingsProvider], which
  /// applies the same rule the enforcement path acts on, so this row cannot
  /// claim a source the safety logic is not counting.
  static String sourceSummary(
    ({SafetySourceReading weather, SafetySourceReading monitor}) sources,
    SafetyFailMode failMode,
  ) {
    String describe(String name, SafetySourceReading reading) =>
        switch (reading) {
          SafetySourceReading.safe => '$name: reporting safe',
          SafetySourceReading.unsafe => '$name: reporting UNSAFE',
          SafetySourceReading.unknown => '$name: connected, not reporting',
          SafetySourceReading.absent => '$name: not connected',
        };

    final anyConnected = sources.weather != SafetySourceReading.absent ||
        sources.monitor != SafetySourceReading.absent;
    if (!anyConnected) {
      return 'No weather device or safety monitor is connected. '
          '${failMode.noSourceConsequence}';
    }
    return '${describe('Weather device', sources.weather)} · '
        '${describe('Safety monitor', sources.monitor)}';
  }

  /// Append the master-switch prerequisite when weather safety is off.
  static String _withPrerequisite(String description, bool masterEnabled) {
    if (masterEnabled) return description;
    return '$description — inactive until "Enable weather safety" is on';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final failMode =
        ref.watch(appSettingsProvider).valueOrNull?.safetyFailMode ??
            SafetyFailMode.failClosed;
    final sources = ref.watch(weatherSafetySourceReadingsProvider);

    return Column(
      children: [
        SettingRow(
          icon: LucideIcons.satelliteDish,
          title: 'Safety sources',
          subtitle: _withPrerequisite(
            sourceSummary(sources, failMode),
            masterEnabled,
          ),
          trailing: const SizedBox.shrink(),
          isMobile: isMobile,
        ),
        SettingRow(
          icon: LucideIcons.alertTriangle,
          title: 'Safety fail mode',
          subtitle: failMode.description,
          trailing: settingsTrailingDropdown(
            context: context,
            value: failMode.label,
            items: SafetyFailModeLabels.labels,
            designWidth: 180,
            isMobile: isMobile,
            onChanged: (value) => ref
                .read(appSettingsProvider.notifier)
                .setSafetyFailMode(SafetyFailModeLabels.fromLabel(value)),
          ),
          isMobile: isMobile,
        ),
      ],
    );
  }
}
