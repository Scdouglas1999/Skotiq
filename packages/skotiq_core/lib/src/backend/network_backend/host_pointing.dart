part of '../network_backend.dart';

/// Pointing requests a client sends to a linked imaging host.
mixin HostPointing on NetworkBackendTransport {
  /// Push a framing target to the imaging host (Plan Tonight handoff).
  Future<void> framingSetTarget({
    required double ra,
    required double dec,
    required String name,
  }) async {
    await _post(
      FramingApi.setTarget,
      body: {'ra': ra, 'dec': dec, 'name': name},
    );
  }

  Future<void> slewToTarget(double ra, double dec) async {
    await _post(FramingApi.slewToTarget, body: {'ra': ra, 'dec': dec});
  }

  /// POST /api/framing/center-on-target: starts the host's centering on a
  /// target and answers the id of the host job that runs it.
  Future<String> startCentering({
    required double raHours,
    required double decDegrees,
    required int maxAttempts,
    required double accuracyArcsec,
    required double exposureSecs,
    required bool syncMount,
  }) async {
    final start = await _post(
      FramingApi.centerOnTarget,
      body: {
        'ra': raHours,
        'dec': decDegrees,
        'maxIterations': maxAttempts,
        'toleranceArcsec': accuracyArcsec,
        'exposureTime': exposureSecs,
        'syncMount': syncMount,
      },
    );
    final jobId = start['jobId'];
    if (jobId is! String || jobId.isEmpty) {
      throw const FormatException('The host did not start a centering job');
    }
    return jobId;
  }

  /// The host job [jobId] once it has ended.
  Future<RemoteJob> awaitJobCompletion(
    String jobId, {
    Duration timeout,
    Duration pollInterval,
  });

  /// Asks the host to stop job [jobId]; it then ends cancelled.
  Future<void> cancelJob(String jobId);
}
