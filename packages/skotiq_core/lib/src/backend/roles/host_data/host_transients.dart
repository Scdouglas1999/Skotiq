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
}
