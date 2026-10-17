// Remote calibration library management.
//
// CRUD + upload endpoints for the three calibration data stores
// (dark_library, flat_history, defect_maps), so an operator on a headless
// Pi/embedded host manages their calibration library from a remote client
// without SSH.
//
// Endpoints (all under /api/calibration):
//
//   Dark library:
//     GET  /api/calibration/darks                    — list (filters)
//     GET  /api/calibration/darks/<id>               — single
//     POST /api/calibration/darks                    — register by path
//     POST /api/calibration/darks/upload             — multipart upload
//     GET  /api/calibration/darks/<id>/download      — stream FITS (Range)
//     DELETE /api/calibration/darks/<id>             — delete row (file?)
//     POST /api/calibration/darks/find-match         — best dark for params
//     POST /api/calibration/darks/backfill-sizes     — verify on-disk state
//
//   Flat history:
//     GET  /api/calibration/flats                    — list (filters)
//     GET  /api/calibration/flats/<id>               — single
//     POST /api/calibration/flats                    — record entry
//     DELETE /api/calibration/flats/<id>             — delete row
//     GET  /api/calibration/flats/recommendation     — exposure suggestion
//
//   Defect maps:
//     GET  /api/calibration/defect-maps              — list (no BLOB)
//     GET  /api/calibration/defect-maps/<id>         — single (binary|json)
//     POST /api/calibration/defect-maps              — register row
//     DELETE /api/calibration/defect-maps/<id>       — delete row (file?)
//     POST /api/calibration/defect-maps/<id>/regenerate — recompute from FITS

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../route_metadata.dart' show backupUploadMaxRequestBodyBytes;
import '../validation.dart';

part 'calibration_handlers/dark_library_handlers.dart';
part 'calibration_handlers/flat_history_handlers.dart';
part 'calibration_handlers/defect_map_handlers.dart';

/// calibration library handlers.
class CalibrationHandlers {
  /// Same 256 MB cap as the backup-upload path. A dark master frame from a
  /// modern full-frame camera is typically 100–200 MB so this is a snug
  /// upper bound that still rejects accidental large-blob uploads.
  static const int _maxDarkUploadBytes = backupUploadMaxRequestBodyBytes;

  /// Default limit on listing endpoints. Picked to fit comfortably in a
  /// single response payload — 100 rows is roughly 20 KB of JSON, well
  /// under the typical 1 MB mobile read budget.
  static const int _defaultListLimit = 100;
  static const int _maxListLimit = 500;

  final ProviderContainer container;

  /// Override the data-root resolution. Used by tests so we don't depend on
  /// `path_provider` being wired up in the widget-test binding.
  final Future<Directory> Function()? dataDirectoryOverride;

  CalibrationHandlers(this.container, {this.dataDirectoryOverride});

  LoggingService get _logger => container.read(loggingServiceProvider);
  SkotiqDatabase get _database => container.read(databaseProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'CalibrationHandlers');
  void _logWarning(String message) =>
      _logger.warning(message, source: 'CalibrationHandlers');

  int _parsePathId(String value, String field) {
    final id = int.tryParse(value);
    if (id == null) {
      throw BadRequestError(
        field: field,
        expected: 'integer',
        message: 'Path segment is not a valid integer',
      );
    }
    return id;
  }

  /// Resolve the calibration directory ($DATA_DIR/calibration/darks).
  /// Created on first use. Honors `SKOTIQ_DATA_DIR` (see
  /// `desktop_logging_init.dart`) so headless deployments under custom
  /// paths land in the right place.
  Future<Directory> _calibrationDarksDir() async {
    final dataDir = await _resolveDataDirectory();
    final dir = Directory(p.join(dataDir.path, 'calibration', 'darks'));
    await dir.create(recursive: true);
    return dir;
  }

  Future<Directory> _resolveDataDirectory() async {
    final override = dataDirectoryOverride;
    if (override != null) {
      return override();
    }
    return resolveSkotiqDataDirectory();
  }

  // Helpers — JSON shape

  Future<Map<String, dynamic>> _darkEntryToWire(DarkLibraryEntry entry) async {
    final file = File(entry.filePath);
    bool exists = false;
    int? fileSize;
    try {
      exists = await file.exists();
      if (exists) {
        fileSize = await file.length();
      }
    } on FileSystemException {
      exists = false;
    }
    return {
      'id': entry.id,
      'filePath': entry.filePath,
      'fileName': p.basename(entry.filePath),
      'exposureDuration': entry.exposureTime,
      'sensorTempC': entry.temperature,
      'gain': entry.gain,
      'offset': entry.offset,
      'binX': entry.binX,
      'binY': entry.binY,
      'frameType': entry.frameType,
      'width': entry.width,
      'height': entry.height,
      'masterPath': entry.masterDarkPath,
      'frameCount': entry.masterFrameCount,
      'createdAt': entry.createdAt.toUtc().toIso8601String(),
      'fileSize': fileSize,
      'fileExists': exists,
    };
  }

  Map<String, dynamic> _flatEntryToJson(FlatHistoryEntry entry) {
    return {
      'id': entry.id,
      'filter': entry.filterName,
      'exposureDuration': entry.exposureTime,
      'histogramTarget': entry.histogramTarget,
      'adu': entry.actualAdu,
      'gain': entry.gain,
      'binning': entry.binning,
      'panelBrightness': entry.panelBrightness,
      'skyAduRate': entry.skyAduRate,
      'twilightPhase': entry.twilightPhase,
      'equipmentProfileId': entry.equipmentProfileId,
      'createdAt': entry.timestamp.toUtc().toIso8601String(),
    };
  }

  Future<Map<String, dynamic>> _defectMapMetadataToJson(
    DefectMapEntry row,
  ) async {
    int? fileSize;
    bool fileExists = false;
    final sp = row.filePath;
    if (sp != null && sp.isNotEmpty) {
      try {
        final file = File(sp);
        fileExists = await file.exists();
        if (fileExists) {
          fileSize = await file.length();
        }
      } on FileSystemException {
        fileExists = false;
      }
    }
    return {
      'id': row.id,
      'cameraId': row.cameraId,
      'width': row.width,
      'height': row.height,
      'temperatureBucketDecicelsius': row.temperatureBucketDecicelsius,
      'defectivePixelCount': row.defectivePixelCount,
      'lastRebuiltAt': row.lastRebuiltAt.toUtc().toIso8601String(),
      'sourceFilePath': row.filePath,
      'fileSize': fileSize,
      'fileExists': fileExists,
    };
  }

  // Helpers — query-param parsing

  int? _parseIntParam(Map<String, String> params, String name) {
    final raw = params[name];
    if (raw == null || raw.isEmpty) return null;
    final value = int.tryParse(raw);
    if (value == null) {
      throw BadRequestError(
        field: name,
        expected: 'integer',
        message: '$name must be an integer, got "$raw"',
      );
    }
    return value;
  }

  double? _parseDoubleParam(Map<String, String> params, String name) {
    final raw = params[name];
    if (raw == null || raw.isEmpty) return null;
    final value = double.tryParse(raw);
    if (value == null) {
      throw BadRequestError(
        field: name,
        expected: 'number',
        message: '$name must be a number, got "$raw"',
      );
    }
    return value;
  }

  DateTime? _parseDateParam(Map<String, String> params, String name) {
    final raw = params[name];
    if (raw == null || raw.isEmpty) return null;
    final asInt = int.tryParse(raw);
    if (asInt != null) {
      return DateTime.fromMillisecondsSinceEpoch(asInt, isUtc: true);
    }
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) {
      throw BadRequestError(
        field: name,
        expected: 'ISO-8601 timestamp or unix-ms integer',
        message: '$name is not a parseable timestamp: "$raw"',
      );
    }
    return parsed;
  }

  int _parseListLimit(Map<String, String> params) {
    final raw = params['limit'];
    if (raw == null || raw.isEmpty) return _defaultListLimit;
    final value = int.tryParse(raw);
    if (value == null || value <= 0) {
      throw BadRequestError(
        field: 'limit',
        expected: 'positive integer',
        message: 'limit must be a positive integer',
      );
    }
    return value > _maxListLimit ? _maxListLimit : value;
  }

  String? _sanitizeDarkFileName(String requested) {
    var name = requested.split(RegExp(r'[\\/]')).last.trim();
    name = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (name.isEmpty || name == '.' || name == '..') return null;
    if (!name.contains('.')) name = '$name.fits';
    final lower = name.toLowerCase();
    if (!lower.endsWith('.fits') &&
        !lower.endsWith('.fit') &&
        !lower.endsWith('.xisf')) {
      return null;
    }
    if (name.length > 120) {
      final ext = lower.endsWith('.fits')
          ? '.fits'
          : (lower.endsWith('.fit') ? '.fit' : '.xisf');
      final stem = name.substring(0, name.length - ext.length);
      final maxStem = 120 - ext.length;
      final safeStem = stem.length <= maxStem
          ? stem
          : stem.substring(0, maxStem);
      name = '$safeStem$ext';
    }
    return name;
  }

  Future<File> _resolveUniquePath(Directory dir, String fileName) async {
    final candidate = File(p.join(dir.path, fileName));
    if (!await candidate.exists()) return candidate;
    final ext = p.extension(fileName);
    final stem = p.basenameWithoutExtension(fileName);
    final timestamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    return File(p.join(dir.path, '${stem}_upload_$timestamp$ext'));
  }
}

// Exposure of `defectMapServiceProvider` lives in skotiq_core; we read
// it via the container so this file does not need a direct provider import.
