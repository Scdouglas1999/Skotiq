part of '../calibration_library_service.dart';

extension _CalibrationLibraryLoading on CalibrationLibraryService {
  Future<List<CalibrationMasterRecord>> _loadAll() async {
    final tags = await _tagsDao.getAllKeyed();

    CalibrationTagEntry? tagFor(CalibrationMasterType type, int id) =>
        tags['${calibrationMasterTypeWireName(type)}:$id'];

    final records = <CalibrationMasterRecord>[];

    final darkRows = await _db.select(_db.darkLibrary).get();
    for (final row in darkRows) {
      final type = row.frameType == 'bias'
          ? CalibrationMasterType.bias
          : CalibrationMasterType.dark;
      final tag = tagFor(type, row.id);
      records.add(
        CalibrationMasterRecord(
          type: type,
          id: row.id,
          filePath: row.masterDarkPath ?? row.filePath,
          isMaster: row.masterDarkPath != null,
          frameCount: row.masterFrameCount,
          exposureSeconds: row.exposureTime,
          temperature: row.temperature,
          gain: row.gain,
          offset: row.offset,
          binX: row.binX,
          binY: row.binY,
          width: row.width,
          height: row.height,
          cameraId: tag?.cameraId,
          createdAt: row.createdAt,
          tags: tag?.tags ?? const [],
          notes: tag?.notes,
          provenance: _provenanceFromTag(tag),
          license: _licenseFromTag(tag),
          sharedBy: tag?.sharedBy,
          publishedRemoteId: tag?.publishedRemoteId,
        ),
      );
    }

    final flatRows = await _flatDao.getAllEntries();
    for (final row in flatRows) {
      final tag = tagFor(CalibrationMasterType.flat, row.id);
      records.add(
        CalibrationMasterRecord(
          type: CalibrationMasterType.flat,
          id: row.id,
          filePath: row.filePath,
          isMaster: true,
          frameCount: row.masterFrameCount,
          temperature: row.temperature,
          gain: row.gain,
          offset: row.offset,
          binX: row.binX,
          binY: row.binY,
          filter: row.filter,
          flatKind: row.flatKind,
          width: row.width,
          height: row.height,
          cameraId: tag?.cameraId,
          opticalTrainId: row.opticalTrainId,
          createdAt: row.createdAt,
          tags: tag?.tags ?? const [],
          notes: tag?.notes,
          provenance: _provenanceFromTag(tag),
          license: _licenseFromTag(tag),
          sharedBy: tag?.sharedBy,
          publishedRemoteId: tag?.publishedRemoteId,
        ),
      );
    }

    final mapRows = await _db.select(_db.defectMaps).get();
    for (final row in mapRows) {
      final tag = tagFor(CalibrationMasterType.defectMap, row.id);
      records.add(
        CalibrationMasterRecord(
          type: CalibrationMasterType.defectMap,
          id: row.id,
          filePath: row.filePath,
          isMaster: true,
          frameCount: row.defectivePixelCount,
          temperature: row.temperatureBucketDecicelsius / 10.0,
          width: row.width,
          height: row.height,
          cameraId: row.cameraId,
          createdAt: row.lastRebuiltAt,
          tags: tag?.tags ?? const [],
          notes: tag?.notes,
        ),
      );
    }

    return records;
  }

  /// [_enrich] over a whole set. The single answer to "what metadata does this
  /// master really carry", shared by [listMasters] and [match] so the library
  /// list and the matcher can never describe the same record differently.
  Future<List<CalibrationMasterRecord>> _enrichAll(
    List<CalibrationMasterRecord> records,
  ) async => [for (final record in records) await _enrich(record)];

  /// Fill missing camera id / temperature / filter from the FITS primary
  /// header, caching the camera id in `calibration_tags`. Best-effort:
  /// returns the record unchanged when the file is missing or unreadable.
  Future<CalibrationMasterRecord> _enrich(
    CalibrationMasterRecord record,
  ) async {
    if (record.type == CalibrationMasterType.defectMap) return record;
    final needsCamera = record.cameraId == null;
    final needsTemp = record.temperature == null;
    final needsFilter =
        record.type == CalibrationMasterType.flat && record.filter == null;
    if (!needsCamera && !needsTemp && !needsFilter) return record;

    final path = record.filePath;
    if (path == null || path.isEmpty) return record;

    Map<String, String> headers;
    try {
      if (!await File(path).exists()) return record;
      headers = await headerReader.readPrimaryHeader(path);
    } catch (e) {
      developer.log(
        'Calibration enrichment skipped for $path: $e',
        name: 'CalibrationLibraryService',
        level: 900,
      );
      return record;
    }

    final camera = needsCamera
        ? FitsHeaderReader.stringValue(headers, 'INSTRUME')
        : record.cameraId;
    final temperature = needsTemp
        ? FitsHeaderReader.firstDouble(headers, const [
            'CCD-TEMP',
            'CCD_TEMP',
            'SET-TEMP',
          ])
        : record.temperature;
    final filterName = needsFilter
        ? FitsHeaderReader.stringValue(headers, 'FILTER')
        : record.filter;

    if (needsCamera && camera != null) {
      // Cache so the header is parsed at most once per artifact.
      try {
        await _tagsDao.upsert(record.type, record.id, cameraId: camera);
      } catch (e) {
        developer.log(
          'Failed to cache camera id for ${record.type.name}#${record.id}: $e',
          name: 'CalibrationLibraryService',
          level: 900,
        );
      }
    }

    return record.copyWith(
      cameraId: camera,
      temperature: temperature,
      filter: filterName,
    );
  }

  Future<void> _deleteFileIfExists(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}
