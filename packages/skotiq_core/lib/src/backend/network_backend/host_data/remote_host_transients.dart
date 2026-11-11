import 'dart:typed_data';

import 'package:skotiq_core/skotiq_core.dart';

/// [HostTransients] on a linked host.
final class RemoteHostTransients implements HostTransients {
  RemoteHostTransients(this._host);

  final NetworkBackend _host;

  @override
  Future<List<Map<String, dynamic>>> getFirstLightCandidates({
    int? sessionId,
  }) => _host.getFirstLightCandidates(sessionId: sessionId);

  @override
  Future<Uint8List> getFirstLightCrop(int id, String stage) =>
      _host.getFirstLightCrop(id, stage);

  @override
  Future<List<Map<String, dynamic>>> getFirstLightHistory({
    required double raDeg,
    required double decDeg,
    double radiusDeg = 0.02,
  }) => _host.getFirstLightHistory(
    raDeg: raDeg,
    decDeg: decDeg,
    radiusDeg: radiusDeg,
  );

  @override
  Future<void> reviewFirstLightCandidate(int id) =>
      _host.reviewFirstLightCandidate(id);

  @override
  Future<void> dismissFirstLightCandidate(int id) =>
      _host.dismissFirstLightCandidate(id);

  @override
  Future<Map<String, dynamic>> getTransientStates() =>
      _host.getTransientStates();

  @override
  Future<void> updateTransientState(String transientId, String state) =>
      _host.updateTransientState(transientId, state);

  @override
  Future<void> clearTransientStates() => _host.clearTransientStates();

  @override
  Future<Map<String, dynamic>> getTransientSettings() =>
      _host.getTransientSettings();

  @override
  Future<void> updateTransientSettings(Map<String, dynamic> settings) =>
      _host.updateTransientSettings(settings);

  @override
  Future<Map<String, dynamic>> getActiveTransients() =>
      _host.getActiveTransients();
}
