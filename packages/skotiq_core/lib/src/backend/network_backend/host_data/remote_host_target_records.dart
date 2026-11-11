import 'package:skotiq_core/skotiq_core.dart';

/// [HostTargetRecords] on a linked host.
final class RemoteHostTargetRecords implements HostTargetRecords {
  RemoteHostTargetRecords(this._host);

  final NetworkBackend _host;

  @override
  Future<List<Map<String, dynamic>>> getAllTargets() => _host.getAllTargets();

  @override
  Future<Map<String, dynamic>?> getTargetById(int id) =>
      _host.getTargetById(id);

  @override
  Future<List<Map<String, dynamic>>> searchTargets(String query) =>
      _host.searchTargets(query);

  @override
  Future<int> createTarget(Map<String, dynamic> target) =>
      _host.createTarget(target);

  @override
  Future<void> updateTarget(int id, Map<String, dynamic> target) =>
      _host.updateTarget(id, target);
}
