import 'package:drift/drift.dart';

import '../backend/skotiq_backend.dart';
import '../database/daos/targets_dao.dart';
import '../database/database.dart' as db;
import 'catalog_target_resolver.dart';
import 'catalog_target_types.dart';
import '../backend/network_backend.dart';
import '../utils/async_scope.dart';
import '../utils/logging_service.dart';

/// Host-aware targets-library CRUD for planetarium and transient flows.
class TargetLibraryService {
  /// [hostRecords] is the linked host's library, or null where the library
  /// is this process's database. [host] is the backend the service was built
  /// for; work refuses to continue once it is stale. [targetsDao] and [logger]
  /// are asked for at each call, and [onLibraryChanged] runs after each write
  /// so the library's watchers re-read.
  TargetLibraryService({
    required AsyncScope<SkotiqBackend> host,
    HostImagingRecords? hostRecords,
    required TargetsDao Function() targetsDao,
    required LoggingService Function() logger,
    required void Function() onLibraryChanged,
  }) : _host = host,
       _hostRecords = hostRecords,
       _targetsDao = targetsDao,
       _logger = logger,
       _onLibraryChanged = onLibraryChanged;

  final AsyncScope<SkotiqBackend> _host;
  final HostImagingRecords? _hostRecords;
  final TargetsDao Function() _targetsDao;
  final LoggingService Function() _logger;
  final void Function() _onLibraryChanged;

  void _ensureSameHost() =>
      _host.ensureCurrent('the target library was being updated');

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
    _ensureSameHost();
    final host = _hostRecords;
    if (host != null) {
      final id = await host.createTarget({
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
      _ensureSameHost();
      _invalidateCatalog();
      return id;
    }

    final targetsDao = _targetsDao();
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
    _ensureSameHost();
    _invalidateCatalog();
    return id;
  }

  /// Resolves an existing library target or creates one on the host/local DB.
  Future<db.DbTarget> ensureCatalogTarget({
    required String targetName,
    required double raHours,
    required double decDegrees,
    String? catalogId,
    String? objectType,
    String? constellation,
    double? magnitude,
    double? sizeArcmin,
  }) async {
    _ensureSameHost();
    final candidates = await _loadTargets();
    _ensureSameHost();
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
    _ensureSameHost();

    final refreshed = await _loadTargets();
    _ensureSameHost();
    for (final target in refreshed) {
      if (target.id == id) {
        return target;
      }
    }

    return db.DbTarget(
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

  /// Saved targets matching [query]: the linked host searches its own
  /// library, this machine its database. Each reads with the object type
  /// the catalog gives it ([withCatalogObjectType]).
  Future<List<db.DbTarget>> searchTargets(String query) async {
    _ensureSameHost();
    final host = _hostRecords;
    final List<db.DbTarget> rows;
    if (host != null) {
      final json = await host.searchTargets(query);
      rows = json.map(db.DbTarget.fromJson).toList();
    } else {
      rows = await _targetsDao().searchTargets(query);
    }
    final typed = await withCatalogObjectTypes(rows, _logger());
    _ensureSameHost();
    return typed;
  }

  Future<List<db.DbTarget>> _loadTargets() async {
    final host = _hostRecords;
    if (host != null) {
      final rows = await host.getAllTargets();
      // Drop rows the host sent without a usable sky coordinate rather than
      // failing the whole library. `_targetFromRemoteJson` refuses to invent an
      // RA/Dec, which is right — but mapping straight over the list would let a
      // single bad row from an older or third-party host take away every target
      // the operator has. Skip the row, say so, and keep the rest.
      final targets = <db.DbTarget>[];
      for (final row in rows) {
        try {
          targets.add(_targetFromRemoteJson(row));
        } on FormatException catch (e) {
          _logger().warning(
            'Skipping a target from the imaging host: $e',
            source: 'TargetLibraryService',
          );
        }
      }
      return List<db.DbTarget>.unmodifiable(targets);
    }
    final dao = _targetsDao();
    return dao.getAllTargets();
  }

  db.DbTarget _targetFromRemoteJson(Map<String, dynamic> json) {
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

    return db.DbTarget(
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

  void _invalidateCatalog() => _onLibraryChanged();
}
