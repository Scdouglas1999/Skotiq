import 'dart:convert';

import 'package:drift/drift.dart';

import '../../database/database.dart';
import 'csv_parser.dart';

class TargetLibraryImportException implements Exception {
  final String message;

  const TargetLibraryImportException(this.message);

  @override
  String toString() => message;
}

/// Strict, all-or-nothing importer for the desktop target library.
///
/// CSV columns are `name, ra, dec, catalogId, objectType`. JSON accepts either
/// a top-level target list or `{ "targets": [...] }`. Every row is validated
/// before the database transaction begins; a bad row never produces a partial
/// import that is reported only as a smaller success count.
class TargetLibraryImporter {
  TargetLibraryImporter(this._database);

  final SkotiqDatabase _database;

  Future<int> importCsv(String content) async {
    if (_hasUnclosedQuote(content)) {
      throw const TargetLibraryImportException(
        'CSV contains an unterminated quoted field.',
      );
    }
    final rows = CsvParser.parse(content);
    if (rows.isEmpty) {
      throw const TargetLibraryImportException('CSV contains no target rows.');
    }

    final first = rows.first
        .map((cell) => _stripBom(cell).trim().toLowerCase())
        .toList(growable: false);
    final hasHeader =
        first.length >= 3 &&
        first[0] == 'name' &&
        {'ra', 'right ascension', 'right_ascension'}.contains(first[1]) &&
        {'dec', 'declination'}.contains(first[2]);
    final dataRows = hasHeader ? rows.skip(1).toList() : rows;
    if (dataRows.isEmpty) {
      throw const TargetLibraryImportException('CSV contains no target rows.');
    }

    final targets = <_ImportedTarget>[];
    for (var index = 0; index < dataRows.length; index++) {
      final rowNumber = index + (hasHeader ? 2 : 1);
      final row = dataRows[index];
      if (row.length < 3) {
        throw TargetLibraryImportException(
          'CSV row $rowNumber must contain at least name, RA, and Dec.',
        );
      }
      targets.add(
        _validateTarget(
          rowNumber: rowNumber,
          source: 'CSV row',
          name: _stripBom(row[0]),
          ra: _parseNumber(row[1]),
          dec: _parseNumber(row[2]),
          catalogId: row.length > 3 ? _blankToNull(row[3]) : null,
          objectType: row.length > 4 ? _blankToNull(row[4]) : null,
        ),
      );
    }
    return _persist(targets);
  }

  Future<int> importJson(String content) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException catch (error) {
      throw TargetLibraryImportException('Invalid JSON: ${error.message}');
    }

    final Object? rawTargets = decoded is List
        ? decoded
        : decoded is Map
        ? decoded['targets']
        : null;
    if (rawTargets is! List) {
      throw const TargetLibraryImportException(
        'JSON must be a target array or an object with a `targets` array.',
      );
    }

    final targets = <_ImportedTarget>[];
    for (var index = 0; index < rawTargets.length; index++) {
      final raw = rawTargets[index];
      final rowNumber = index + 1;
      if (raw is! Map) {
        throw TargetLibraryImportException(
          'JSON target $rowNumber must be an object.',
        );
      }
      final target = Map<String, dynamic>.from(raw);
      targets.add(
        _validateTarget(
          rowNumber: rowNumber,
          source: 'JSON target',
          name: target['name'],
          ra: target['ra'],
          dec: target['dec'],
          catalogId: _optionalString(target, 'catalogId', rowNumber),
          objectType: _optionalString(target, 'objectType', rowNumber),
          magnitude: _optionalNumber(target, 'magnitude', rowNumber),
          constellation: _optionalString(target, 'constellation', rowNumber),
          notes: _optionalString(target, 'notes', rowNumber),
        ),
      );
    }
    return _persist(targets);
  }

  Future<int> _persist(List<_ImportedTarget> targets) {
    return _database.transaction(() async {
      for (final target in targets) {
        await _database.targetsDao.createTarget(target.toCompanion());
      }
      return targets.length;
    });
  }

  _ImportedTarget _validateTarget({
    required int rowNumber,
    required String source,
    required Object? name,
    required Object? ra,
    required Object? dec,
    String? catalogId,
    String? objectType,
    num? magnitude,
    String? constellation,
    String? notes,
  }) {
    if (name is! String || name.trim().isEmpty || name.trim().length > 200) {
      throw TargetLibraryImportException(
        '$source $rowNumber has an invalid target name (1–200 characters required).',
      );
    }
    if (ra is! num || !ra.toDouble().isFinite || ra < 0 || ra >= 24) {
      throw TargetLibraryImportException(
        '$source $rowNumber has invalid RA; use decimal hours from 0 up to 24.',
      );
    }
    if (dec is! num || !dec.toDouble().isFinite || dec < -90 || dec > 90) {
      throw TargetLibraryImportException(
        '$source $rowNumber has invalid Dec; use degrees from -90 to 90.',
      );
    }
    if (magnitude != null && !magnitude.toDouble().isFinite) {
      throw TargetLibraryImportException(
        '$source $rowNumber has an invalid magnitude.',
      );
    }
    return _ImportedTarget(
      name: name.trim(),
      ra: ra.toDouble(),
      dec: dec.toDouble(),
      catalogId: _blankToNull(catalogId),
      objectType: _blankToNull(objectType),
      magnitude: magnitude?.toDouble(),
      constellation: _blankToNull(constellation),
      notes: _blankToNull(notes),
    );
  }

  String? _optionalString(
    Map<String, dynamic> json,
    String key,
    int rowNumber,
  ) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) {
      throw TargetLibraryImportException(
        'JSON target $rowNumber has a non-string `$key` value.',
      );
    }
    return value;
  }

  num? _optionalNumber(Map<String, dynamic> json, String key, int rowNumber) {
    final value = json[key];
    if (value == null) return null;
    if (value is! num) {
      throw TargetLibraryImportException(
        'JSON target $rowNumber has a non-numeric `$key` value.',
      );
    }
    return value;
  }

  static num? _parseNumber(String value) => double.tryParse(value.trim());

  static String _stripBom(String value) =>
      value.startsWith('\uFEFF') ? value.substring(1) : value;

  static String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static bool _hasUnclosedQuote(String content) {
    var quoted = false;
    for (var i = 0; i < content.length; i++) {
      if (content[i] != '"') continue;
      if (quoted && i + 1 < content.length && content[i + 1] == '"') {
        i++;
      } else {
        quoted = !quoted;
      }
    }
    return quoted;
  }
}

class _ImportedTarget {
  const _ImportedTarget({
    required this.name,
    required this.ra,
    required this.dec,
    this.catalogId,
    this.objectType,
    this.magnitude,
    this.constellation,
    this.notes,
  });

  final String name;
  final double ra;
  final double dec;
  final String? catalogId;
  final String? objectType;
  final double? magnitude;
  final String? constellation;
  final String? notes;

  TargetsCompanion toCompanion() => TargetsCompanion.insert(
    name: name,
    ra: ra,
    dec: dec,
    catalogId: Value(catalogId),
    objectType: Value(objectType),
    magnitude: Value(magnitude),
    constellation: Value(constellation),
    notes: Value(notes),
  );
}
