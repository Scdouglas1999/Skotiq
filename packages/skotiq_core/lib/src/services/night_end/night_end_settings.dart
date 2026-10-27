import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/daos/settings_dao.dart';
import '../../providers/database_provider.dart';
import '../darkroom_build_plan.dart' show defaultMinRetainedArea;
import '../end_of_night_calibration/eon_settings.dart';

/// What happens when the night's imaging ends, step by step. Each step has
/// its own switch; a step that is off is skipped and the history says so.
class NightEndAutomationSettings {
  const NightEndAutomationSettings({
    this.calibrate = true,
    this.build = true,
    this.allowIncompleteCalibration = false,
    this.deliver = true,
    this.morningMessage = true,
    this.minRetainedArea = defaultMinRetainedArea,
  });

  /// Take darks and bias for the night's lights and build their masters.
  /// The same switch as Settings > End-of-night calibration.
  final bool calibrate;

  /// Build masters for every target the night imaged, from all its nights.
  /// On unless the operator turned it off: an unset key reads as on, on a
  /// fresh install and on one that never touched the switch.
  final bool build;

  /// Explicit permission to omit or scale calibration in unattended builds.
  final bool allowIncompleteCalibration;

  /// Hand finished masters, previews and the report to the delivery
  /// destinations.
  final bool deliver;

  /// Send one message when the night-end work is done.
  final bool morningMessage;

  /// The smallest common crop, as a fraction of the field, a build accepts
  /// on its own. A smaller one waits at the framing check.
  final double minRetainedArea;

  static const calibrateKey = EonSettings.enabledKey;
  static const buildKey = 'post_session.auto_integrate';
  static const allowIncompleteCalibrationKey =
      'darkroom.night_end.allow_incomplete_calibration';
  static const deliverKey = 'darkroom.night_end.deliver';
  static const morningMessageKey = 'darkroom.night_end.morning_message';
  static const minRetainedAreaKey = 'darkroom.night_end.min_field';

  static const minField = .3;
  static const maxField = 1.0;

  /// Whether any step runs at all.
  bool get anyOn => calibrate || build;

  static Future<NightEndAutomationSettings> load(SettingsDao dao) async {
    final field = double.tryParse(
      await dao.getSetting(minRetainedAreaKey) ?? '',
    );
    return NightEndAutomationSettings(
      calibrate: await dao.getSetting(calibrateKey) != 'false',
      build: await dao.getSetting(buildKey) != 'false',
      allowIncompleteCalibration:
          await dao.getSetting(allowIncompleteCalibrationKey) == 'true',
      deliver: await dao.getSetting(deliverKey) != 'false',
      morningMessage: await dao.getSetting(morningMessageKey) != 'false',
      minRetainedArea: field == null || !field.isFinite
          ? defaultMinRetainedArea
          : field.clamp(minField, maxField).toDouble(),
    );
  }

  /// The steps that are on, in the order they run, for a status line.
  List<String> get stepsOn => [
    if (calibrate) 'calibrate',
    if (build) 'build',
    if (build && deliver) 'deliver',
    if (anyOn && morningMessage) 'message',
  ];
}

final nightEndAutomationSettingsProvider =
    FutureProvider.autoDispose<NightEndAutomationSettings>((ref) {
      return NightEndAutomationSettings.load(ref.watch(settingsDaoProvider));
    });

/// One line for the Darkroom header: what the end of the night will do.
final nightEndAutomationSummaryProvider = Provider.autoDispose<String?>((ref) {
  final settings = ref.watch(nightEndAutomationSettingsProvider).valueOrNull;
  if (settings == null) return null;
  final steps = settings.stepsOn;
  if (steps.isEmpty) return 'Night end: off';
  return 'Night end: ${steps.join(', ')}';
});

/// Writes the night-end switches.
class NightEndAutomationActions {
  const NightEndAutomationActions(this._ref);

  final Ref _ref;

  Future<void> _write(String key, String value) async {
    await _ref.read(settingsDaoProvider).setSetting(key, value);
    _ref.invalidate(nightEndAutomationSettingsProvider);
  }

  Future<void> setCalibrate(bool on) =>
      _write(NightEndAutomationSettings.calibrateKey, '$on');
  Future<void> setBuild(bool on) =>
      _write(NightEndAutomationSettings.buildKey, '$on');
  Future<void> setAllowIncompleteCalibration(bool on) =>
      _write(NightEndAutomationSettings.allowIncompleteCalibrationKey, '$on');
  Future<void> setDeliver(bool on) =>
      _write(NightEndAutomationSettings.deliverKey, '$on');
  Future<void> setMorningMessage(bool on) =>
      _write(NightEndAutomationSettings.morningMessageKey, '$on');
  Future<void> setMinRetainedArea(double value) => _write(
    NightEndAutomationSettings.minRetainedAreaKey,
    value
        .clamp(
          NightEndAutomationSettings.minField,
          NightEndAutomationSettings.maxField,
        )
        .toStringAsFixed(2),
  );
}

final nightEndAutomationActionsProvider = Provider(
  NightEndAutomationActions.new,
);
