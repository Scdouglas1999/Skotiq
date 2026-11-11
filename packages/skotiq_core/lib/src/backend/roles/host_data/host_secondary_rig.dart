import 'package:skotiq_core/skotiq_core.dart';

/// The secondary rig of a linked imaging host.
abstract interface class HostSecondaryRig {
  /// Host-authoritative secondary-rig status. These operations deliberately
  /// live on [NetworkBackend] rather than the generic sequencer role because
  /// the local implementation is still an FRB-owned background capture loop.
  Future<Map<String, dynamic>> secondaryRigGetStatus();

  Future<void> secondaryRigStart(Map<String, dynamic> config);

  Future<void> secondaryRigStop();
}
