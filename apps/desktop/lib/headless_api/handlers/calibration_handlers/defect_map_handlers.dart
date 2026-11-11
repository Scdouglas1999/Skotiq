part of '../calibration_handlers.dart';

extension CalibrationDefectMapHandlers on CalibrationHandlers {
  Map<String, dynamic> _defectMapStatusJson(DefectMapStatus status) => {
    'cameraId': status.cameraId,
    'width': status.width,
    'height': status.height,
    'temperatureBucketDecicelsius': status.temperatureBucket.decicelsius,
    'defectivePixelCount': status.defectivePixelCount,
    'lastRebuiltUnixSeconds': status.lastRebuiltUnixSeconds,
    'applyDuringCapture': status.applyDuringCapture,
    'storedOnDisk': status.storedOnDisk,
  };

  Future<Map<String, dynamic>> _defectMapSettingsJson() async {
    final stored = await container.read(settingsDaoProvider).getAllSettings();
    return {
      'autoApply': stored[DefectMapSettingsKeys.autoApply] == 'true',
      'method': DefectMapMethod.fromWire(
        stored[DefectMapSettingsKeys.method],
      ).wireValue,
      'kernelDiameter': DefectMapKernelSize.fromDiameter(
        int.tryParse(stored[DefectMapSettingsKeys.kernel] ?? '') ?? 3,
      ).diameter,
      'saveOriginal': stored[DefectMapSettingsKeys.saveOriginal] == 'true',
    };
  }

  Future<Response> handleGetDefectMapSettings(Request request) async {
    return jsonOk(await _defectMapSettingsJson());
  }

  Future<Response> handleUpdateDefectMapSettings(Request request) async {
    _logInfo('[API] POST /api/calibration/defect-maps/settings');
    final payload = await readJsonObject(request);
    final updates = <String, String>{};

    if (payload.containsKey('autoApply')) {
      updates[DefectMapSettingsKeys.autoApply] = requireBool(
        payload,
        'autoApply',
      ).toString();
    }
    if (payload.containsKey('saveOriginal')) {
      updates[DefectMapSettingsKeys.saveOriginal] = requireBool(
        payload,
        'saveOriginal',
      ).toString();
    }
    if (payload.containsKey('method')) {
      final value = requireString(payload, 'method');
      if (!DefectMapMethod.values.any((method) => method.wireValue == value)) {
        throw BadRequestError(
          field: 'method',
          expected: 'one_of:median,mean,gaussian',
          message: 'Unknown defect-map replacement method',
        );
      }
      updates[DefectMapSettingsKeys.method] = value;
    }
    if (payload.containsKey('kernelDiameter')) {
      final value = requireInt(payload, 'kernelDiameter');
      if (!DefectMapKernelSize.values.any(
        (kernel) => kernel.diameter == value,
      )) {
        throw BadRequestError(
          field: 'kernelDiameter',
          expected: 'one_of:3,5,7',
          message: 'Defect-map kernel must be 3, 5, or 7 pixels',
        );
      }
      updates[DefectMapSettingsKeys.kernel] = value.toString();
    }

    if (updates.isEmpty) {
      throw BadRequestError(
        field: 'body',
        expected: 'at_least_one_defect_map_setting',
        message: 'At least one defect-map setting is required',
      );
    }
    await container.read(settingsDaoProvider).setSettings(updates);
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.settings,
      action: HostMutationAction.updated,
      extra: const {'namespace': 'defect-map'},
    );
    return jsonOk(await _defectMapSettingsJson());
  }

  /// GET /api/calibration/defect-maps/status
  Future<Response> handleGetDefectMapStatus(Request request) async {
    final payload = request.url.queryParameters;
    final cameraId = requireString(payload, 'cameraId');
    final width = requireInt(payload, 'width', min: 1);
    final height = requireInt(payload, 'height', min: 1);
    final temperature = requireDouble(
      payload,
      'sensorTemperatureCelsius',
      min: -273.15,
      max: 100,
    );
    final status = await container
        .read(defectMapServiceProvider)
        .getStatus(
          cameraId: cameraId,
          width: width,
          height: height,
          sensorTemperatureCelsius: temperature,
        );
    return jsonOk({
      'status': status == null ? null : _defectMapStatusJson(status),
    });
  }

  /// POST /api/calibration/defect-maps/clear
  Future<Response> handleClearDefectMap(Request request) async {
    _logInfo('[API] POST /api/calibration/defect-maps/clear');
    final payload = await readJsonObject(request);
    final cameraId = requireString(payload, 'cameraId');
    final width = requireInt(payload, 'width', min: 1);
    final height = requireInt(payload, 'height', min: 1);
    final temperature = requireDouble(
      payload,
      'sensorTemperatureCelsius',
      min: -273.15,
      max: 100,
    );
    await container
        .read(defectMapServiceProvider)
        .clear(
          cameraId: cameraId,
          width: width,
          height: height,
          sensorTemperatureCelsius: temperature,
        );
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.settings,
      action: HostMutationAction.updated,
      extra: const {'namespace': 'defect-map'},
    );
    return jsonOk({'status': 'cleared'});
  }

  /// POST /api/calibration/defect-maps/sequencer-apply
  Future<Response> handleApplyDefectMapToSequencer(Request request) async {
    _logInfo('[API] POST /api/calibration/defect-maps/sequencer-apply');
    final payload = await readJsonObject(request);
    final cameraId = requireString(payload, 'cameraId');
    final width = requireInt(payload, 'width', min: 1);
    final height = requireInt(payload, 'height', min: 1);
    final temperature = requireDouble(
      payload,
      'sensorTemperatureCelsius',
      min: -273.15,
      max: 100,
    );
    final enabled = requireBool(payload, 'enabled');
    final methodRaw = requireString(payload, 'method');
    final method = DefectMapMethod.values
        .where((value) => value.wireValue == methodRaw)
        .firstOrNull;
    if (method == null) {
      throw BadRequestError(
        field: 'method',
        expected: 'one_of:median,mean,gaussian',
      );
    }
    final kernelRaw = requireInt(payload, 'kernelDiameter');
    final kernel = DefectMapKernelSize.values
        .where((value) => value.diameter == kernelRaw)
        .firstOrNull;
    if (kernel == null) {
      throw BadRequestError(field: 'kernelDiameter', expected: 'one_of:3,5,7');
    }
    final saveOriginal = requireBool(payload, 'saveOriginal');

    await container
        .read(defectMapServiceProvider)
        .applyToSequencer(
          cameraId: cameraId,
          width: width,
          height: height,
          sensorTemperatureCelsius: temperature,
          enabled: enabled,
          method: method,
          kernel: kernel,
          saveOriginal: saveOriginal,
        );
    return jsonOk({'status': 'applied'});
  }

  /// GET /api/calibration/defect-maps
  Future<Response> handleListDefectMaps(Request request) async {
    final params = request.url.queryParameters;

    final cameraId = params['cameraId'];
    final width = _parseIntParam(params, 'width');
    final height = _parseIntParam(params, 'height');
    final bucket = _parseIntParam(params, 'temperatureBucketDecicelsius');

    final db = _database;
    var query = db.select(db.defectMaps);
    if (cameraId != null) {
      query = query..where((t) => t.cameraId.equals(cameraId));
    }
    if (width != null) {
      query = query..where((t) => t.width.equals(width));
    }
    if (height != null) {
      query = query..where((t) => t.height.equals(height));
    }
    if (bucket != null) {
      query = query
        ..where((t) => t.temperatureBucketDecicelsius.equals(bucket));
    }
    query = query..orderBy([(t) => OrderingTerm.desc(t.lastRebuiltAt)]);

    final rows = await query.get();
    final list = <Map<String, dynamic>>[];
    for (final row in rows) {
      list.add(await _defectMapMetadataToJson(row));
    }
    return jsonOk({'defectMaps': list, 'count': list.length});
  }

  /// GET /api/calibration/defect-maps/{id}
  ///
  /// `?format=binary` (default) — returns the BLOB bitmap with
  /// `content-type: application/octet-stream`, `accept-ranges: bytes`, and
  /// metadata headers (`x-defect-map-camera-id`, `-width`, `-height`,
  /// `-temperature-bucket-decicelsius`, `-defective-pixel-count`).
  ///
  /// `?format=json` — returns metadata + base64 bitmap in a JSON wrapper.
  Future<Response> handleGetDefectMap(Request request, String id) async {
    final iid = _parsePathId(id, 'id');
    final format = (request.url.queryParameters['format'] ?? 'binary')
        .toLowerCase();

    final db = _database;
    final row = await (db.select(
      db.defectMaps,
    )..where((t) => t.id.equals(iid))).getSingleOrNull();
    if (row == null) {
      return jsonNotFound({
        'error': 'defect_map_not_found',
        'message': 'No defect map with id $iid',
      });
    }

    if (format == 'json') {
      final meta = await _defectMapMetadataToJson(row);
      return jsonOk({
        'defectMap': {...meta, 'bitmapBase64': base64Encode(row.bitmap)},
      });
    }
    if (format != 'binary') {
      throw BadRequestError(
        field: 'format',
        expected: '"binary" or "json"',
        message: 'Unsupported format "$format"',
      );
    }

    return contentResponse(
      row.bitmap,
      contentType: 'application/octet-stream',
      contentLength: row.bitmap.length,
      headers: {
        'accept-ranges': 'bytes',
        'x-defect-map-id': row.id.toString(),
        'x-defect-map-camera-id': row.cameraId,
        'x-defect-map-width': row.width.toString(),
        'x-defect-map-height': row.height.toString(),
        'x-defect-map-temperature-bucket-decicelsius': row
            .temperatureBucketDecicelsius
            .toString(),
        'x-defect-map-defective-pixel-count': row.defectivePixelCount
            .toString(),
      },
    );
  }

  /// POST /api/calibration/defect-maps — register a new map by metadata +
  /// base64 bitmap. The Rust defect-map service is the usual producer; this
  /// endpoint exists for restore + cross-machine sync.
  Future<Response> handleRegisterDefectMap(Request request) async {
    _logInfo('[API] POST /api/calibration/defect-maps');
    final payload = await readJsonObject(request);

    final cameraId = requireString(payload, 'cameraId');
    final width = requireInt(payload, 'width', min: 1);
    final height = requireInt(payload, 'height', min: 1);
    final bucket = requireInt(payload, 'temperatureBucketDecicelsius');
    final defectCount = requireInt(payload, 'defectCount', min: 0);
    final sourceFilePath = optionalString(payload, 'sourceFilePath');

    final bitmapField = requireString(payload, 'bitmap');
    Uint8List bitmap;
    try {
      bitmap = base64Decode(bitmapField);
    } on FormatException {
      throw BadRequestError(
        field: 'bitmap',
        expected: 'base64-encoded bytes',
        message: 'bitmap field is not valid base64',
      );
    }

    final expectedLength = ((width * height) + 7) ~/ 8;
    if (bitmap.length != expectedLength) {
      throw BadRequestError(
        field: 'bitmap',
        expected: 'bytes of length $expectedLength',
        message:
            'bitmap byte-length (${bitmap.length}) does not match width × '
            'height = $width × $height (expected $expectedLength bytes)',
      );
    }

    final db = _database;
    final id = await db
        .into(db.defectMaps)
        .insert(
          DefectMapsCompanion.insert(
            cameraId: cameraId,
            width: width,
            height: height,
            temperatureBucketDecicelsius: bucket,
            bitmap: bitmap,
            defectivePixelCount: defectCount,
            filePath: Value(sourceFilePath),
          ),
        );
    final row = await (db.select(
      db.defectMaps,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    if (row == null) {
      throw HandlerFailure(
        code: 'defect_map_register_failed',
        message: 'Failed to read back newly-registered defect map',
      );
    }
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.settings,
      action: HostMutationAction.created,
      extra: const {'namespace': 'defect-map'},
    );
    return jsonCreated({'defectMap': await _defectMapMetadataToJson(row)});
  }

  /// POST /api/calibration/defect-maps/build
  ///
  /// Builds a defect map host-side from a set of dark frames. The remote
  /// client cannot run a local file picker over the host's filesystem, so it
  /// supplies either an explicit list of on-host dark-frame paths
  /// (`darkFramePaths`) or a single host directory (`darkFramesDirectory`)
  /// that the host enumerates for FITS/XISF dark frames. Mirrors the status
  /// envelope returned by [handleRegenerateDefectMap].
  Future<Response> handleBuildDefectMap(Request request) async {
    _logInfo('[API] POST /api/calibration/defect-maps/build');
    final payload = await readJsonObject(request);

    final cameraId = requireString(payload, 'cameraId');
    final temperatureCelsius = requireDouble(
      payload,
      'sensorTemperatureCelsius',
    );

    final explicitPaths = optionalList<String>(payload, 'darkFramePaths');
    final directory = optionalString(payload, 'darkFramesDirectory');

    List<String> darkFramePaths;
    if (explicitPaths != null && explicitPaths.isNotEmpty) {
      darkFramePaths = explicitPaths;
    } else if (directory != null) {
      darkFramePaths = await _enumerateDarkFrames(directory);
      if (darkFramePaths.isEmpty) {
        throw HandlerFailure(
          code: 'defect_map_no_darks_in_directory',
          message: 'No dark frames (.fits/.fit/.fts/.xisf) found in $directory',
          statusCode: 409,
          details: {'darkFramesDirectory': directory},
        );
      }
    } else {
      throw BadRequestError(
        field: 'darkFramePaths',
        expected: 'array<string> or darkFramesDirectory',
        message:
            'Supply either darkFramePaths (host paths) or darkFramesDirectory',
      );
    }

    final service = container.read(defectMapServiceProvider);
    final status = await service.build(
      cameraId: cameraId,
      darkFramePaths: darkFramePaths,
      sensorTemperatureCelsius: temperatureCelsius,
    );
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.settings,
      action: HostMutationAction.updated,
      extra: const {'namespace': 'defect-map'},
    );

    return jsonOk({
      'status': {
        'cameraId': status.cameraId,
        'width': status.width,
        'height': status.height,
        'temperatureBucketDecicelsius': status.temperatureBucket.decicelsius,
        'defectivePixelCount': status.defectivePixelCount,
        'lastRebuiltUnixSeconds': status.lastRebuiltUnixSeconds,
        'applyDuringCapture': status.applyDuringCapture,
        'storedOnDisk': status.storedOnDisk,
      },
    });
  }

  /// POST /api/calibration/defect-maps/apply
  ///
  /// Toggles whether the stored defect map for `cameraId` is applied to
  /// lights at capture time. The map itself already lives host-side; this is
  /// a pure preference flip with no file transfer.
  Future<Response> handleApplyDefectMap(Request request) async {
    _logInfo('[API] POST /api/calibration/defect-maps/apply');
    final payload = await readJsonObject(request);

    final cameraId = requireString(payload, 'cameraId');
    final applyDuringCapture = requireBool(payload, 'applyDuringCapture');

    final service = container.read(defectMapServiceProvider);
    await service.apply(
      cameraId: cameraId,
      applyDuringCapture: applyDuringCapture,
    );
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.settings,
      action: HostMutationAction.updated,
      extra: const {'namespace': 'defect-map'},
    );

    return jsonOk({
      'cameraId': cameraId,
      'applyDuringCapture': applyDuringCapture,
    });
  }

  /// Enumerate dark-frame files (FITS/XISF) directly under [directoryPath].
  /// Non-recursive: callers point at the directory that holds the darks.
  Future<List<String>> _enumerateDarkFrames(String directoryPath) async {
    final directory = Directory(directoryPath);
    if (!await directory.exists()) {
      throw HandlerFailure(
        code: 'defect_map_darks_dir_missing',
        message: 'Dark-frame directory does not exist: $directoryPath',
        statusCode: 409,
        details: {'darkFramesDirectory': directoryPath},
      );
    }
    const darkExtensions = {'.fits', '.fit', '.fts', '.xisf'};
    final paths = <String>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (darkExtensions.contains(ext)) {
        paths.add(entity.path);
      }
    }
    paths.sort();
    return paths;
  }

  /// DELETE /api/calibration/defect-maps/{id}?deleteFile=true
  Future<Response> handleDeleteDefectMap(Request request, String id) async {
    final iid = _parsePathId(id, 'id');
    _logInfo('[API] DELETE /api/calibration/defect-maps/$iid');
    final deleteFile =
        request.url.queryParameters['deleteFile']?.toLowerCase() == 'true';

    final db = _database;
    final row = await (db.select(
      db.defectMaps,
    )..where((t) => t.id.equals(iid))).getSingleOrNull();
    if (row == null) {
      return jsonNotFound({
        'error': 'defect_map_not_found',
        'message': 'No defect map with id $iid',
      });
    }

    bool fileDeleted = false;
    if (deleteFile && row.filePath != null && row.filePath!.isNotEmpty) {
      try {
        final file = File(row.filePath!);
        if (await file.exists()) {
          await file.delete();
          fileDeleted = true;
        }
      } on PathAccessException catch (e) {
        _logWarning('Permission denied deleting defect-map $iid file: $e');
        return jsonForbidden({
          'error': 'permission_denied',
          'path': row.filePath,
        });
      } on FileSystemException catch (e) {
        _logWarning(
          'Failed to delete defect-map $iid source file: ${e.message}',
        );
        await (db.delete(db.defectMaps)..where((t) => t.id.equals(iid))).go();
        publishHostMutationFromContainer(
          container,
          entityType: HostMutationEntity.settings,
          action: HostMutationAction.deleted,
          extra: const {'namespace': 'defect-map'},
        );
        return jsonOk({
          'deleted': true,
          'fileDeleted': false,
          'fileError': e.message,
        });
      }
    }

    final rowsAffected = await (db.delete(
      db.defectMaps,
    )..where((t) => t.id.equals(iid))).go();
    if (rowsAffected > 0) {
      publishHostMutationFromContainer(
        container,
        entityType: HostMutationEntity.settings,
        action: HostMutationAction.deleted,
        extra: const {'namespace': 'defect-map'},
      );
    }
    return jsonOk({'deleted': rowsAffected > 0, 'fileDeleted': fileDeleted});
  }

  /// POST /api/calibration/defect-maps/{id}/regenerate
  ///
  /// Recomputes the defect map by re-running the Rust defect-map build
  /// against the source file. Returns 409 when the source path is unset
  /// or no longer on disk.
  Future<Response> handleRegenerateDefectMap(Request request, String id) async {
    final iid = _parsePathId(id, 'id');
    _logInfo('[API] POST /api/calibration/defect-maps/$iid/regenerate');

    final db = _database;
    final row = await (db.select(
      db.defectMaps,
    )..where((t) => t.id.equals(iid))).getSingleOrNull();
    if (row == null) {
      return jsonNotFound({
        'error': 'defect_map_not_found',
        'message': 'No defect map with id $iid',
      });
    }
    final sourcePath = row.filePath;
    if (sourcePath == null || sourcePath.isEmpty) {
      return jsonConflict({
        'error': 'defect_map_no_source',
        'message':
            'Defect map $iid was registered without a sourceFilePath; '
            'cannot regenerate',
      });
    }
    final source = File(sourcePath);
    if (!await source.exists()) {
      return jsonConflict({
        'error': 'defect_map_source_missing',
        'message':
            'Defect map $iid source file is no longer on disk: $sourcePath',
        'sourceFilePath': sourcePath,
      });
    }

    final service = container.read(defectMapServiceProvider);
    final temperatureCelsius = row.temperatureBucketDecicelsius / 10.0;
    final status = await service.build(
      cameraId: row.cameraId,
      darkFramePaths: [sourcePath],
      sensorTemperatureCelsius: temperatureCelsius,
    );

    // After build the row in Drift may have been updated by the native
    // side via a separate code path, or we may need to reflect the new
    // count + last-rebuilt-at directly. Refresh the row and use the
    // returned status as the source of truth for the response.
    final refreshed = await (db.select(
      db.defectMaps,
    )..where((t) => t.id.equals(iid))).getSingleOrNull();
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.settings,
      action: HostMutationAction.updated,
      extra: const {'namespace': 'defect-map'},
    );
    return jsonOk({
      'status': {
        'cameraId': status.cameraId,
        'width': status.width,
        'height': status.height,
        'temperatureBucketDecicelsius': status.temperatureBucket.decicelsius,
        'defectivePixelCount': status.defectivePixelCount,
        'lastRebuiltUnixSeconds': status.lastRebuiltUnixSeconds,
        'applyDuringCapture': status.applyDuringCapture,
        'storedOnDisk': status.storedOnDisk,
      },
      if (refreshed != null)
        'defectMap': await _defectMapMetadataToJson(refreshed),
    });
  }
}
