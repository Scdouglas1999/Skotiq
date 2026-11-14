import '../../../services/end_of_night_calibration/eon_service.dart';

/// The night a linked imaging host is running: its scheduled start, its
/// end-of-night steps, its manual loop and its history.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostNightControl {
  Future<EonStatus?> cancelHostEndOfNight();

  Future<void> cancelHostScheduledStart();

  Future<EonStatus?> confirmHostEndOfNightCapped();

  Future<Map<String, dynamic>?> getHostNightHistory();

  Future<void> stopHostManualLoop();

  Future<void> startHostManualLoop(Map<String, dynamic> request);
}
