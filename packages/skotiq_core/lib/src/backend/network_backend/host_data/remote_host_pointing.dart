import 'package:skotiq_core/skotiq_core.dart';

/// [HostPointing] on a linked host.
final class RemoteHostPointing implements HostPointing {
  RemoteHostPointing(this._host);

  final NetworkBackend _host;

  @override
  Future<void> framingSetTarget({
    required double ra,
    required double dec,
    required String name,
  }) => _host.framingSetTarget(ra: ra, dec: dec, name: name);

  @override
  Future<void> slewToTarget(double ra, double dec) =>
      _host.slewToTarget(ra, dec);
}
