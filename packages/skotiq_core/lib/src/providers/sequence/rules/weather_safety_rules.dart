import '../../../models/equipment/equipment_models.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../../models/settings/app_settings.dart';
import '../../settings_provider.dart';
import '../../equipment_provider.dart';
import '../../weather_providers.dart';
import '../sequence_validation.dart';

/// Catches the fail-closed weather gate BEFORE the run wastes a slew.
///
/// The Rust `WeatherUnsafe` trigger is always armed. With weather safety enabled
/// and the fail mode set to `fail_closed`, a rig that has NO weather source
/// (no weather device, no safety monitor) is treated as unsafe the moment the
/// trigger first evaluates — and the configured action is `ParkAndAbort`. The
/// run therefore unparks, slews, takes a frame or two, then parks and aborts.
///
/// The gate is the fail-closed contract working as designed, so the rule's job
/// is to make it visible before it fires: unannounced, the operator learns of
/// it only from the log, typically the next morning, having lost the night.
class WeatherSafetyNoSourceRule implements RefAwareSequenceValidator {
  @override
  String get name => 'WeatherSafetyNoSource';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final weatherSettings = ctx.ref.read(weatherSettingsProvider);
    if (!weatherSettings.weatherSafetyEnabled) {
      // Safety disabled: the trigger is neutralised elsewhere (the start paths
      // push `fail_open`), so there is nothing to warn about.
      return const [];
    }

    // `appSettingsProvider` is an AsyncNotifier; `.read()` yields AsyncValue and
    // `.value` is null while loading (see `settings_rules.dart`).
    final failMode = ctx.ref.read(appSettingsProvider).value?.safetyFailMode;
    // A missing source blocks fail-closed runs and warns for permissive modes.
    // Loading settings retain the shipped fail-closed default.
    final failsClosed =
        failMode == null || failMode == SafetyFailMode.failClosed;

    final weatherConnected =
        ctx.ref.read(weatherStateProvider).connectionState ==
        DeviceConnectionState.connected;
    final safetyMonitorConnected =
        ctx.ref.read(safetyMonitorStateProvider).connectionState ==
        DeviceConnectionState.connected;
    if (weatherConnected || safetyMonitorConnected) return const [];

    if (!failsClosed) {
      return const [
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.equipment,
          title: 'No Weather Safety Readings',
          description:
              'No weather device or safety monitor is connected. '
              'The selected safety policy allows this run to continue without '
              'readings that could detect unsafe conditions.',
          resolutionHint:
              'Connect a weather device or safety monitor, or review '
              'the policy in Settings > Automation & Safety before starting.',
        ),
      ];
    }

    return [
      const ValidationIssue(
        severity: ValidationSeverity.error,
        category: ValidationCategory.equipment,
        title: 'Weather Safety Will Abort This Run',
        description:
            'Weather safety is enabled and set to fail closed, but no weather '
            'device or safety monitor is connected. With no reading to trust, '
            'the safety gate treats conditions as unsafe and the run will park '
            'and abort shortly after it starts.',
        resolutionHint:
            'Connect a weather device or safety monitor, switch the safety fail '
            'mode to fail open in Settings > Automation & Safety, or turn '
            'weather safety off for this session.',
      ),
    ];
  }
}
