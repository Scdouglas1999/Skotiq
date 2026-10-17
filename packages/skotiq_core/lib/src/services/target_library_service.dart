import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../backend/skotiq_backend.dart';
import '../database/database.dart' as db;
import '../providers/backend_provider.dart';
import '../providers/database_provider.dart';
import 'catalog_target_resolver.dart';
import 'logging_service.dart';

/// Host-aware targets-library CRUD for planetarium and transient flows.
class TargetLibraryService {
  TargetLibraryService(Ref ref, {SkotiqBackend? backend})
    : _ref = ref,
      _backend = backend ?? ref.read(backendProvider),
      _backendNotifier = ref.read(backendProvider.notifier);

  final Ref _ref;
  final SkotiqBackend _backend;
  final BackendNotifier _backendNotifier;
  bool _retired = false;

  bool get _hasAuthority =>
      !_retired && _backendNotifier.isCurrentBackend(_backend);

  void retire() => _retired = true;

  void _ensureAuthority() {
    if (_hasAuthority) return;
    throw StateError(
      'The imaging host changed while the target library was being updated. '
      'The stale result was discarded; try the action again on the current '
      'host.',
    );
  }

  /// Creates a row in the targets library on the imaging host (remote) or
  /// local SQLite (FFI). Returns the new target id.
  Future<int> createTarget({
    required String name,
    required double raHours,
    required double decDegrees,
    String? catalogId,
    String? objectType,
    String? constellation,
    double? magnitude,
    double? sizeArcmin,
    double? positionAngle,
    double minAltitude = 30.0,
    String? notes,
    bool isFavorite = false,
    int priority = 5,
  }) async {
    _ensureAuthority();
    final backend = _backend;
    if (backend is NetworkBackend) {
      final id = await backend.createTarget({
        'name': name,
        'ra': raHours,
        'dec': decDegrees,
        if (catalogId != null) 'catalogId': catalogId,
        if (objectType != null) 'objectType': objectType,
        if (constellation != null) 'constellation': constellation,
        if (magnitude != null) 'magnitude': magnitude,
        if (sizeArcmin != null) 'sizeArcmin': sizeArcmin,
        if (positionAngle != null) 'positionAngle': positionAngle,
        'minAltitude': minAltitude,
        if (notes != null) 'notes': notes,
        'isFavorite': isFavorite,
        'priority': priority,
      });
      _ensureAuthority();
      _invalidateCatalog();
      return id;
    }

    final targetsDao = _ref.read(targetsDaoProvider);
    final id = await targetsDao.createTarget(
      db.TargetsCompanion.insert(
        name: name,
        catalogId: Value(catalogId),
        ra: raHours,
        dec: decDegrees,
        objectType: Value(objectType),
        constellation: Value(constellation),
        magnitude: Value(magnitude),
        sizeArcmin: Value(sizeArcmin),
        positionAngle: Value(positionAngle),
        minAltitude: Value(minAltitude),
        notes: Value(notes),
        isFavorite: Value(isFavorite),
        priority: Value(priority),
      ),
    );
    _ensureAuthority();
    _invalidateCatalog();
    return id;
  }

  /// Resolves an existing library target or creates one on the host/local DB.
  Future<db.Target> ensureCatalogTarget({
    required String targetName,
    required double raHours,
    required double decDegrees,
    String? catalogId,
    String? objectType,
    String? constellation,
    double? magnitude,
    double? sizeArcmin,
  }) async {
    _ensureAuthority();
    final candidates = await _loadTargets();
    _ensureAuthority();
    final existing = resolveDbTargetForCatalog(
      candidates: candidates,
      targetName: targetName,
      catalogId: catalogId,
      raHours: raHours,
      decDegrees: decDegrees,
    );
    if (existing != null) {
      return existing;
    }

    final id = await createTarget(
      name: targetName,
      raHours: raHours,
      decDegrees: decDegrees,
      catalogId: catalogId ?? targetName,
      objectType: objectType,
      constellation: constellation,
      magnitude: magnitude,
      sizeArcmin: sizeArcmin,
    );
    _ensureAuthority();

    final refreshed = await _loadTargets();
    _ensureAuthority();
    for (final target in refreshed) {
      if (target.id == id) {
        return target;
      }
    }

    return db.Target(
      id: id,
      name: targetName,
      catalogId: catalogId ?? targetName,
      objectType: objectType,
      ra: raHours,
      dec: decDegrees,
      constellation: constellation,
      magnitude: magnitude,
      sizeArcmin: sizeArcmin,
      minAltitude: 30.0,
      priority: 5,
      totalPlannedSubs: 0,
      capturedSubs: 0,
      totalIntegrationSecs: 0,
      goalIntegrationSecs: 0,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      isFavorite: false,
    );
  }

  Future<List<db.Target>> _loadTargets() async {
    final backend = _backend;
    if (backend is NetworkBackend) {
      final rows = await backend.getAllTargets();
      // Drop rows the host sent without a usable sky coordinate rather than
      // failing the whole library. `_targetFromRemoteJson` refuses to invent an
      // RA/Dec, which is right — but mapping straight over the list would let a
      // single bad row from an older or third-party host take away every target
      // the operator has. Skip the row, say so, and keep the rest.
      final targets = <db.Target>[];
      for (final row in rows) {
        try {
          targets.add(_targetFromRemoteJson(row));
        } on FormatException catch (e) {
          _ref
              .read(loggingServiceProvider)
              .warning(
                'Skipping a target from the imaging host: $e',
                source: 'TargetLibraryService',
              );
        }
      }
      return List<db.Target>.unmodifiable(targets);
    }
    final dao = _ref.read(targetsDaoProvider);
    return dao.getAllTargets();
  }

  db.Target _targetFromRemoteJson(Map<String, dynamic> json) {
    DateTime dateTime(Object? value) {
      if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
      if (value is String) {
        return DateTime.tryParse(value) ??
            DateTime.fromMillisecondsSinceEpoch(0);
      }
      return DateTime.fromMillisecondsSinceEpoch(0);
    }

    // RA/Dec are the only fields on this row a mount can be commanded to. A
    // missing coordinate must fail the load loudly: coalescing it to 0 would
    // mint a target that *looks* valid and points at 0h/+0deg, and the slew
    // path has no way to tell that apart from a genuine equatorial target.
    double coordinate(String key) {
      final value = json[key];
      if (value is num) return value.toDouble();
      throw FormatException(
        'Target ${json['id']} from the imaging host is missing a numeric '
        '"$key" — refusing to substitute a sky coordinate.',
      );
    }

    return db.Target(
      id: (json['id'] as num).toInt(),
      name: json['name'] as String? ?? 'Untitled target',
      catalogId: json['catalogId'] as String?,
      objectType: json['objectType'] as String?,
      ra: coordinate('ra'),
      dec: coordinate('dec'),
      positionAngle: (json['positionAngle'] as num?)?.toDouble(),
      magnitude: (json['magnitude'] as num?)?.toDouble(),
      constellation: json['constellation'] as String?,
      sizeArcmin: (json['sizeArcmin'] as num?)?.toDouble(),
      minAltitude: (json['minAltitude'] as num?)?.toDouble() ?? 30,
      priority: (json['priority'] as num?)?.toInt() ?? 5,
      totalPlannedSubs: (json['totalPlannedSubs'] as num?)?.toInt() ?? 0,
      capturedSubs: (json['capturedSubs'] as num?)?.toInt() ?? 0,
      totalIntegrationSecs:
          (json['totalIntegrationSecs'] as num?)?.toDouble() ?? 0,
      goalIntegrationSecs:
          (json['goalIntegrationSecs'] as num?)?.toDouble() ?? 0,
      filterProgress: json['filterProgress'] as String?,
      notes: json['notes'] as String?,
      createdAt: dateTime(json['createdAt']),
      updatedAt: dateTime(json['updatedAt']),
      isFavorite: json['isFavorite'] as bool? ?? false,
    );
  }

  void _invalidateCatalog() {
    _ref.invalidate(allDbTargetsProvider);
    _ref.invalidate(favoriteDbTargetsProvider);
  }
}

final targetLibraryServiceProvider = Provider<TargetLibraryService>((ref) {
  final backend = ref.watch(backendProvider);
  final service = TargetLibraryService(ref, backend: backend);
  ref.onDispose(service.retire);
  return service;
});
