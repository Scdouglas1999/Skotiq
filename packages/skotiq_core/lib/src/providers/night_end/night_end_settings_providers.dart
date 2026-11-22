import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/night_end/night_end_settings.dart';
import '../database_provider.dart';

final nightEndAutomationSettingsProvider =
    FutureProvider.autoDispose<NightEndAutomationSettings>((ref) {
      return NightEndAutomationSettings.load(ref.watch(settingsDaoProvider));
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

/// One line for the Darkroom header: what the end of the night will do.
final nightEndAutomationSummaryProvider = Provider.autoDispose<String?>((ref) {
  final settings = ref.watch(nightEndAutomationSettingsProvider).valueOrNull;
  if (settings == null) return null;
  final steps = settings.stepsOn;
  if (steps.isEmpty) return 'Night end: off';
  return 'Night end: ${steps.join(', ')}';
});

final nightEndAutomationActionsProvider = Provider(
  NightEndAutomationActions.new,
);
