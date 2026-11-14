/// Post-session processing passes run by a linked imaging host on its own
/// files.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostPostSession {
  Future<Map<String, dynamic>> postSessionAnalyzeNight(
    Map<String, dynamic> args,
  );

  Future<Map<String, dynamic>> postSessionBuildMasterFlat(
    Map<String, dynamic> args,
  );

  Future<Map<String, dynamic>> postSessionColorCalibrate(
    Map<String, dynamic> args,
  );

  Future<Map<String, dynamic>> postSessionDetectStars(
    Map<String, dynamic> args,
  );

  Future<Map<String, dynamic>> postSessionDrizzleIntegrate(
    Map<String, dynamic> args,
  );

  Future<Map<String, dynamic>> postSessionExtractBackground(
    Map<String, dynamic> args,
  );

  Future<Map<String, dynamic>> postSessionIntegrate(Map<String, dynamic> args);

  Future<Map<String, dynamic>> postSessionMasterAccumulate(
    Map<String, dynamic> args,
  );

  Future<bool> getAutoIntegrationEnabled();

  Future<void> setAutoIntegrationEnabled(bool enabled);
}
