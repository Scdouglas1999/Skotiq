part of '../network_backend.dart';

mixin _NetworkBackendDomainOperations on NetworkBackendTransport {
  Future<void> deleteTarget(int id) async {
    await _delete(TargetApi.deleteTarget, path: {'id': id});
  }

  Future<List<Map<String, dynamic>>> getFavoriteTargets() async {
    final response = await _get(TargetApi.getFavoriteTargets);
    return _domainObjectRows(response, 'targets', 'GET /api/targets/favorites');
  }

  Future<List<Map<String, dynamic>>> getTargetsByType(String objectType) async {
    final response = await _get(
      TargetApi.getTargetsByType,
      query: {'type': objectType},
    );
    return _domainObjectRows(response, 'targets', 'GET /api/targets/by-type');
  }

  Future<List<Map<String, dynamic>>> getTargetsByPriority(int priority) async {
    final response = await _get(
      TargetApi.getTargetsByPriority,
      query: {'priority': priority.toString()},
    );
    return _domainObjectRows(
      response,
      'targets',
      'GET /api/targets/by-priority',
    );
  }

  Future<void> updateSequence(int id, Map<String, dynamic> sequence) async {
    await _put(
      SequenceManagementApi.updateSequence,
      path: {'id': id},
      body: sequence,
    );
  }
}

extension _NetworkBackendDomainOperationsHelpers on NetworkBackendTransport {
  List<Map<String, dynamic>> _domainObjectRows(
    Map<String, dynamic> response,
    String field,
    String request,
  ) {
    final raw = response[field];
    if (raw is! List) {
      throw FormatException(
        '$request returned a missing or non-list `$field` field',
      );
    }
    final rows = <Map<String, dynamic>>[];
    for (var index = 0; index < raw.length; index++) {
      final row = raw[index];
      if (row is! Map) {
        throw FormatException(
          '$request returned a non-object `$field[$index]` row',
        );
      }
      rows.add(row.cast<String, dynamic>());
    }
    return rows;
  }

  Map<String, dynamic>? _domainNullableObject(
    Map<String, dynamic> response,
    String field,
    String request,
  ) {
    if (!response.containsKey(field)) {
      throw FormatException('$request returned no `$field` field');
    }
    final raw = response[field];
    if (raw == null) return null;
    if (raw is! Map) {
      throw FormatException('$request returned a non-object `$field` field');
    }
    return raw.cast<String, dynamic>();
  }

  int _domainId(Map<String, dynamic> response, String request) {
    final raw = response['id'];
    if (raw is! num ||
        !raw.isFinite ||
        raw != raw.truncateToDouble() ||
        raw < 1) {
      throw FormatException('$request returned no positive integer `id` field');
    }
    return raw.toInt();
  }
}
