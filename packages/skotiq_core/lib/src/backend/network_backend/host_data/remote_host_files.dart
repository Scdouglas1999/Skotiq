import 'package:skotiq_core/skotiq_core.dart';

/// [HostFiles] on a linked host.
final class RemoteHostFiles implements HostFiles {
  RemoteHostFiles(this._host);

  final NetworkBackend _host;

  @override
  Future<Map<String, dynamic>> validateRemoteDirectory(
    String path, {
    bool mustExist = false,
    bool mustBeWritable = false,
  }) => _host.validateRemoteDirectory(
    path,
    mustExist: mustExist,
    mustBeWritable: mustBeWritable,
  );

  @override
  Future<DiskSpaceInfo?> getHostCaptureDiskSpace() =>
      _host.getHostCaptureDiskSpace();
}
