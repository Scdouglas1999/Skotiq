part of '../network_backend.dart';

/// Pointing requests a client sends to a linked imaging host.
final class HostPointing {
  HostPointing(this._host);

  final NetworkBackend _host;

  /// Push a framing target to the imaging host (Plan Tonight handoff).
  Future<void> framingSetTarget({
    required double ra,
    required double dec,
    required String name,
  }) async {
    await _host._post(
      FramingApi.setTarget,
      body: {'ra': ra, 'dec': dec, 'name': name},
    );
  }

  Future<void> slewToTarget(double ra, double dec) async {
    await _host._post(FramingApi.slewToTarget, body: {'ra': ra, 'dec': dec});
  }
}
