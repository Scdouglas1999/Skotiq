import 'package:skotiq_core/skotiq_core.dart';

/// [HostSecondaryRig] on a linked host.
final class RemoteHostSecondaryRig implements HostSecondaryRig {
  RemoteHostSecondaryRig(this._host);

  final NetworkBackend _host;

  @override
  Future<Map<String, dynamic>> secondaryRigGetStatus() =>
      _host.secondaryRigGetStatus();

  @override
  Future<void> secondaryRigStart(Map<String, dynamic> config) =>
      _host.secondaryRigStart(config);

  @override
  Future<void> secondaryRigStop() => _host.secondaryRigStop();
}
