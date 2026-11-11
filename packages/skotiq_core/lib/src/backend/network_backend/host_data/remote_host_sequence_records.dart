import 'package:skotiq_core/skotiq_core.dart';

/// [HostSequenceRecords] on a linked host.
final class RemoteHostSequenceRecords implements HostSequenceRecords {
  RemoteHostSequenceRecords(this._host);

  final NetworkBackend _host;

  @override
  Future<int> createSequence(Map<String, dynamic> sequence) =>
      _host.createSequence(sequence);

  @override
  Future<int> duplicateSequence(int sourceId, String newName) =>
      _host.duplicateSequence(sourceId, newName);

  @override
  Future<List<Map<String, dynamic>>> getSequenceTemplates() =>
      _host.getSequenceTemplates();

  @override
  Future<List<Map<String, dynamic>>> getSequenceList() =>
      _host.getSequenceList();
}
