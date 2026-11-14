import 'dart:typed_data';

/// Transient alerts and first-light candidates kept by a linked imaging host.
///
/// The remote half of a feature whose local half is a service or DAO in this
/// process; reached through `backend.remoteHost`, which is null locally.
abstract interface class HostTransients {
  Future<Uint8List> exportFirstLightAavso(
    int id, {
    required double magZeroPoint,
    String? standardBand,
  });

  Future<Uint8List> exportFirstLightMpc(int id);

  Future<Map<String, dynamic>> submitFirstLightToTns(int id);

  Future<List<Map<String, dynamic>>> getFirstLightCandidates({int? sessionId});

  Future<Uint8List> getFirstLightCrop(int id, String stage);

  Future<List<Map<String, dynamic>>> getFirstLightHistory({
    required double raDeg,
    required double decDeg,
    double radiusDeg = 0.02,
  });

  Future<void> reviewFirstLightCandidate(int id);

  Future<void> dismissFirstLightCandidate(int id);

  Future<Map<String, dynamic>> getTransientStates();

  Future<void> updateTransientState(String transientId, String state);

  Future<void> clearTransientStates();

  Future<Map<String, dynamic>> getTransientSettings();

  Future<void> updateTransientSettings(Map<String, dynamic> settings);

  Future<Map<String, dynamic>> getActiveTransients();
}
