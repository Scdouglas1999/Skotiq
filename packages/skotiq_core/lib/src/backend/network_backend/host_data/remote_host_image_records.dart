import 'package:skotiq_core/skotiq_core.dart';

/// [HostImageRecords] on a linked host.
final class RemoteHostImageRecords implements HostImageRecords {
  RemoteHostImageRecords(this._host);

  final NetworkBackend _host;

  @override
  Future<List<Map<String, dynamic>>> getAllImageRows() =>
      _host.getAllImageRows();

  @override
  Future<Map<String, dynamic>?> getCapturedImageById(int id) =>
      _host.getCapturedImageById(id);

  @override
  Future<List<Map<String, dynamic>>> getSessionImageRows(int sessionId) =>
      _host.getSessionImageRows(sessionId);

  @override
  Future<List<Map<String, dynamic>>> getImagesForTarget(int targetId) =>
      _host.getImagesForTarget(targetId);
}
