part of '../network_backend.dart';

/// The night a linked imaging host is running: its scheduled start, its
/// end-of-night steps, its manual loop and its history.
final class HostNightControl {
  HostNightControl(this._host);

  final NetworkBackend _host;

  /// Remote-only: stop the host's end-of-night calibration (skip the darks).
  Future<EonStatus?> cancelHostEndOfNight() async {
    final response = await _host._post(
      CalibrationApi.cancelEndOfNight,
      body: const {},
      maxAttempts: 1,
    );
    return EonStatus.fromHostJson(response['status']);
  }

  /// Remote-only: cancel the host's scheduled start.
  Future<void> cancelHostScheduledStart() async {
    await _host._post(
      SequencerApi.cancelScheduledStart,
      body: const {},
      maxAttempts: 1,
    );
  }

  /// Remote-only: tell the host the telescope is capped for its darks.
  Future<EonStatus?> confirmHostEndOfNightCapped() async {
    final response = await _host._post(
      CalibrationApi.confirmEndOfNightCapped,
      body: const {},
      maxAttempts: 1,
    );
    return EonStatus.fromHostJson(response['status']);
  }

  /// What the host's Tonight has gathered tonight from live events: guide
  /// steps, autofocus runs, dithers, flips, lost stars, recent solves and the
  /// cooler history.
  Future<Map<String, dynamic>> getHostNightHistory() =>
      _host._get(RuntimeStateApi.nightHistory);

  /// Stop the host's manual Loop, whichever window started it.
  Future<void> stopHostManualLoop() async {
    await _host._post(RuntimeStateApi.stopManualLoop, body: const {}, maxAttempts: 1);
  }

  /// Start the manual Loop on the host with [request] (see
  /// [manualLoopRequestJson]). The loop runs on the host; its progress comes
  /// back on the `manualLoop` runtime channel.
  Future<void> startHostManualLoop(Map<String, dynamic> request) async {
    await _host._post(RuntimeStateApi.startManualLoop, body: request, maxAttempts: 1);
  }
}
