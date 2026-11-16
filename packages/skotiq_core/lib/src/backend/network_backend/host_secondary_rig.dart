part of '../network_backend.dart';

/// The secondary rig of a linked imaging host.
mixin HostSecondaryRig on NetworkBackendTransport {
  /// Host-authoritative secondary-rig status. These operations deliberately
  /// live on [NetworkBackend] rather than the generic sequencer role because
  /// the local implementation is still an FRB-owned background capture loop.
  Future<Map<String, dynamic>> secondaryRigGetStatus() {
    return _get(SequencerApi.secondaryRigStatus);
  }

  Future<void> secondaryRigStart(Map<String, dynamic> config) async {
    await _post(SequencerApi.secondaryRigStart, body: config);
  }

  Future<void> secondaryRigStop() async {
    await _post(SequencerApi.secondaryRigStop);
  }
}
