import '../database/daos/settings_dao.dart';
import '../models/darkroom/target_standing.dart';

/// The project rule and the user's placements, as the settings store them.
extension TargetStandingSettings on SettingsDao {
  Future<ProjectRule> readProjectRule() async => ProjectRule.fromSettings(
    minutes: await getSetting(ProjectRule.minKeptMinutesKey),
    frames: await getSetting(ProjectRule.minKeptFramesKey),
  );

  Future<void> writeProjectRule(ProjectRule rule) =>
      setSettings(rule.toSettings());

  Future<TargetPlacements> readTargetPlacements() async =>
      TargetPlacements.decode(await getSetting(TargetPlacements.settingsKey));

  Future<void> writeTargetPlacements(TargetPlacements placements) =>
      setSetting(TargetPlacements.settingsKey, placements.encode());
}
