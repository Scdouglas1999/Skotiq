part of '../calibration_handlers.dart';

extension CalibrationDarkLibraryHandlers on CalibrationHandlers {
  // Calibration settings

  Future<Map<String, dynamic>> _calibrationSettingsJson() async {
    final stored = await container.read(settingsDaoProvider).getAllSettings();

    String? pathSetting(String key) {
      final value = stored[key]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    return {
      'autoCalibrate': stored['calibration.auto_calibrate'] == 'true',
      'masterFlatPath': pathSetting('calibration.master_flat_path'),
      'masterBiasPath': pathSetting('calibration.master_bias_path'),
      'autoDarkFromLibrary':
          stored['calibration.auto_dark_from_library'] != 'false',
      'manualDarkPath': pathSetting('calibration.manual_dark_path'),
    };
  }

  Future<Response> handleGetCalibrationSettings(Request request) async {
    _logInfo('[API] GET /api/calibration/settings');
    return jsonOk(await _calibrationSettingsJson());
  }

  Future<Response> handleUpdateCalibrationSettings(Request request) async {
    _logInfo('[API] POST /api/calibration/settings');
    final payload = await readJsonObject(request);
    final updates = <String, String>{};

    if (payload.containsKey('autoCalibrate')) {
      updates['calibration.auto_calibrate'] = requireBool(
        payload,
        'autoCalibrate',
      ).toString();
    }
    if (payload.containsKey('autoDarkFromLibrary')) {
      updates['calibration.auto_dark_from_library'] = requireBool(
        payload,
        'autoDarkFromLibrary',
      ).toString();
    }
    for (final entry in const {
      'masterFlatPath': 'calibration.master_flat_path',
      'masterBiasPath': 'calibration.master_bias_path',
      'manualDarkPath': 'calibration.manual_dark_path',
    }.entries) {
      if (payload.containsKey(entry.key)) {
        updates[entry.value] = _validatedCalibrationFilePath(
          payload,
          entry.key,
        );
      }
    }

    if (updates.isEmpty) {
      throw BadRequestError(
        field: 'body',
        expected: 'at_least_one_calibration_setting',
        message: 'At least one calibration setting is required',
      );
    }

    await container.read(settingsDaoProvider).setSettings(updates);
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.settings,
      action: HostMutationAction.updated,
      extra: const {'namespace': 'calibration'},
    );
    return jsonOk(await _calibrationSettingsJson());
  }

  String _validatedCalibrationFilePath(
    Map<String, dynamic> payload,
    String field,
  ) {
    final raw = payload[field];
    if (raw == null) return '';
    if (raw is! String) {
      throw BadRequestError(field: field, expected: 'string_or_null');
    }
    final value = raw.trim();
    if (value.isEmpty) return '';
    if (value.length > 4096) {
      throw BadRequestError(
        field: field,
        expected: 'host_fits_path',
        message: 'Calibration file path exceeds 4096 characters',
      );
    }
    if (!p.isAbsolute(value)) {
      throw BadRequestError(
        field: field,
        expected: 'absolute_host_path',
        message: 'Calibration file path must be absolute on the imaging host',
      );
    }
    final extension = p.extension(value).toLowerCase();
    if (!const {'.fits', '.fit', '.fts', '.xisf'}.contains(extension)) {
      throw BadRequestError(
        field: field,
        expected: 'fits_or_xisf_file',
        message: 'Calibration master must be a FITS or XISF file',
      );
    }
    if (!File(value).existsSync()) {
      throw BadRequestError(
        field: field,
        expected: 'existing_host_file',
        message: 'Calibration file does not exist on the imaging host',
      );
    }
    return value;
  }

  // Dark library

  Future<Map<String, dynamic>> _darkSettingsJson() async {
    final stored = await container.read(settingsDaoProvider).getAllSettings();
    final temperature = double.tryParse(
      stored[darkLibraryTempToleranceKey] ?? '',
    );
    return {
      'autoCalibrate': stored['calibration.auto_calibrate'] == 'true',
      'temperatureTolerance':
          temperature ?? DarkLibraryMatchTolerances.defaults.temperatureC,
    };
  }

  Future<Response> handleGetDarkSettings(Request request) async {
    _logInfo('[API] GET /api/calibration/darks/settings');
    return jsonOk(await _darkSettingsJson());
  }

  Future<Response> handleUpdateDarkSettings(Request request) async {
    _logInfo('[API] POST /api/calibration/darks/settings');
    final payload = await readJsonObject(request);
    final autoCalibrate = optionalBool(payload, 'autoCalibrate');
    final temperature = optionalDouble(
      payload,
      'temperatureTolerance',
      min: 0,
      max: 20,
    );
    if (autoCalibrate == null && temperature == null) {
      throw BadRequestError(
        field: 'body',
        expected: 'autoCalibrate_or_temperatureTolerance',
        message: 'At least one dark-library setting is required',
      );
    }
    await container.read(settingsDaoProvider).setSettings({
      if (autoCalibrate != null)
        'calibration.auto_calibrate': autoCalibrate.toString(),
      if (temperature != null)
        darkLibraryTempToleranceKey: temperature.toString(),
    });
    return jsonOk(await _darkSettingsJson());
  }

  String _darkFrameType(Map<String, dynamic> payload) {
    final frameType = optionalString(payload, 'frameType') ?? 'dark';
    if (frameType != 'dark' && frameType != 'bias') {
      throw BadRequestError(
        field: 'frameType',
        expected: 'one_of:dark,bias',
        message: 'Frame type must be dark or bias',
      );
    }
    return frameType;
  }

  DarkGroupKey _darkGroupFromPayload(Map<String, dynamic> payload) {
    return DarkGroupKey(
      exposureTime: requireDouble(payload, 'exposureTime', min: 0, max: 86400),
      gain: requireInt(payload, 'gain', min: 0),
      offset: requireInt(payload, 'offset', min: 0),
      binX: requireInt(payload, 'binX', min: 1, max: 16),
      binY: requireInt(payload, 'binY', min: 1, max: 16),
      frameType: _darkFrameType(payload),
    );
  }

  Future<Response> handleCreateMasterDark(Request request) async {
    _logInfo('[API] POST /api/calibration/darks/create-master');
    final payload = await readJsonObject(request);
    final group = _darkGroupFromPayload(payload);
    final outputPath = requireString(payload, 'outputPath', maxLength: 4096);
    if (!p.isAbsolute(outputPath)) {
      throw BadRequestError(
        field: 'outputPath',
        expected: 'absolute_path',
        message: 'Master-dark output path must be absolute on the imaging host',
      );
    }
    final service = container.read(darkLibraryServiceProvider);
    final rawPaths = payload['framePaths'];
    if (rawPaths != null) {
      if (rawPaths is! List || rawPaths.any((p) => p is! String)) {
        throw BadRequestError(
          field: 'framePaths',
          expected: 'array_of_strings',
        );
      }
      return _createMasterFromPaths(group, rawPaths.cast<String>(), outputPath);
    }
    final frames = await service.getEntriesForGroup(group);
    final rawFrames = frames
        .where((entry) => entry.masterDarkPath == null)
        .toList(growable: false);
    if (rawFrames.length < 2) {
      throw BadRequestError(
        field: 'group',
        expected: 'at_least_two_raw_frames',
        message:
            'Need at least 2 raw matching frames; found ${rawFrames.length}',
      );
    }
    final id = await service.createMasterDark(
      frames: rawFrames,
      outputPath: outputPath,
    );
    return jsonOk({'id': id, 'frameCount': rawFrames.length});
  }

  /// Build a master from an explicit list of frames on the host, without
  /// registering each raw frame first. The frames must belong to [group]; the
  /// builder refuses a set whose headers disagree on exposure, gain, offset or
  /// binning.
  Future<Response> _createMasterFromPaths(
    DarkGroupKey group,
    List<String> framePaths,
    String outputPath,
  ) async {
    if (framePaths.length < 2) {
      throw BadRequestError(
        field: 'framePaths',
        expected: 'at_least_two_paths',
        message: 'A master needs at least 2 frames; got ${framePaths.length}',
      );
    }
    for (final path in framePaths) {
      if (!p.isAbsolute(path) || !File(path).existsSync()) {
        throw BadRequestError(
          field: 'framePaths',
          expected: 'existing_absolute_host_paths',
          message: 'No frame exists at $path',
        );
      }
    }
    final build = container.read(calibrationMasterBuildProvider);
    final built = await build(
      CalibrationMasterBuildRequest(
        kind: group.frameType,
        framePaths: framePaths,
        outputPath: outputPath,
      ),
    );
    final id = await container
        .read(darkLibraryServiceProvider)
        .registerMaster(built, frameType: group.frameType);
    return jsonOk({
      'id': id,
      'frameCount': built.frameCount,
      'leakingFrames': built.leakingFrames,
      'masterMean': built.masterMean,
    });
  }

  Future<Response> handleCleanDarkOrphans(Request request) async {
    _logInfo('[API] POST /api/calibration/darks/clean-orphans');
    final removed = await container
        .read(darkLibraryServiceProvider)
        .cleanOrphanedEntries();
    return jsonOk({'removed': removed});
  }

  Future<Response> handleClearDarkLibrary(Request request) async {
    _logInfo('[API] POST /api/calibration/darks/clear');
    final payload = await readJsonObject(request);
    final deleteFiles = optionalBool(payload, 'deleteFiles') ?? false;
    final service = container.read(darkLibraryServiceProvider);
    final removed = (await service.getAllEntries()).length;
    await service.clearLibrary(deleteFiles: deleteFiles);
    return jsonOk({'removed': removed});
  }

  Future<Response> handleDeleteDarkGroup(Request request) async {
    _logInfo('[API] POST /api/calibration/darks/delete-group');
    final payload = await readJsonObject(request);
    final group = _darkGroupFromPayload(payload);
    final deleteFiles = optionalBool(payload, 'deleteFiles') ?? false;
    final service = container.read(darkLibraryServiceProvider);
    final entries = await service.getEntriesForGroup(group);
    await service.deleteEntries(
      entries.map((entry) => entry.id).toList(growable: false),
      deleteFile: deleteFiles,
    );
    return jsonOk({'removed': entries.length});
  }

  /// GET /api/calibration/darks
  Future<Response> handleListDarks(Request request) async {
    _logInfo('[API] GET /api/calibration/darks');
    final params = request.url.queryParameters;

    final exposureSeconds = _parseDoubleParam(params, 'exposureSeconds');
    final temperatureC = _parseDoubleParam(params, 'temperatureC');
    final gain = _parseIntParam(params, 'gain');
    final limit = _parseListLimit(params);

    final entries = await _database.darkLibraryDao.listFiltered(
      exposureSeconds: exposureSeconds,
      gain: gain,
      temperatureCelsius: temperatureC,
      limit: limit,
    );

    final json = <Map<String, dynamic>>[];
    for (final entry in entries) {
      json.add(await _darkEntryToWire(entry));
    }
    return jsonOk({'darks': json, 'count': json.length});
  }

  /// GET /api/calibration/darks/{id}
  Future<Response> handleGetDark(Request request, String id) async {
    _logInfo('[API] GET /api/calibration/darks/$id');
    final iid = _parsePathId(id, 'id');
    final entry = await _database.darkLibraryDao.getEntryById(iid);
    if (entry == null) {
      return jsonNotFound({
        'error': 'dark_not_found',
        'message': 'No dark library entry with id $iid',
      });
    }
    return jsonOk({'dark': await _darkEntryToWire(entry)});
  }

  /// POST /api/calibration/darks  — register an existing file by path.
  Future<Response> handleRegisterDark(Request request) async {
    _logInfo('[API] POST /api/calibration/darks');
    final payload = await readJsonObject(request);

    final filePath = requireString(payload, 'filePath');
    final exposureDuration = requireDouble(payload, 'exposureDuration', min: 0);
    final gain = optionalInt(payload, 'gain') ?? 0;
    final offset = optionalInt(payload, 'offset') ?? 0;
    final binX = optionalInt(payload, 'binX', min: 1) ?? 1;
    final binY = optionalInt(payload, 'binY', min: 1) ?? 1;
    final sensorTempC = optionalDouble(payload, 'sensorTempC');
    final frameType = optionalString(payload, 'frameType') ?? 'dark';
    final frameCount = optionalInt(payload, 'frameCount');
    final masterPath = optionalString(payload, 'masterPath');
    final width = optionalInt(payload, 'width');
    final height = optionalInt(payload, 'height');

    if (frameType != 'dark' && frameType != 'bias') {
      throw BadRequestError(
        field: 'frameType',
        expected: '"dark" or "bias"',
        message: 'frameType must be "dark" or "bias", got "$frameType"',
      );
    }

    final file = File(filePath);
    if (!await file.exists()) {
      return jsonBadRequest({
        'error': 'dark_file_not_found',
        'message': 'No file exists at $filePath',
        'filePath': filePath,
      });
    }

    final companion = DarkLibraryCompanion.insert(
      filePath: filePath,
      exposureTime: exposureDuration,
      temperature: Value(sensorTempC),
      gain: Value(gain),
      offset: Value(offset),
      binX: Value(binX),
      binY: Value(binY),
      frameType: Value(frameType),
      width: Value(width),
      height: Value(height),
      masterDarkPath: Value(masterPath),
      masterFrameCount: Value(frameCount),
    );

    final id = await _database.darkLibraryDao.addEntry(companion);
    final entry = await _database.darkLibraryDao.getEntryById(id);
    if (entry == null) {
      // Should not happen — we just inserted, but treat as a HandlerFailure
      // so the operator sees a structured error rather than a generic 500.
      throw HandlerFailure(
        code: 'dark_register_failed',
        message: 'Failed to read back newly-created dark library entry',
      );
    }
    return jsonCreated({'dark': await _darkEntryToWire(entry)});
  }

  /// POST /api/calibration/darks/upload — multipart-ish (FITS body + JSON
  /// metadata in query params).
  ///
  /// We deliberately don't pull a full MIME multipart parser into the
  /// dependency closure (the `shelf` ecosystem has no canonical multipart
  /// helper at our minor version). Instead we accept the binary FITS as
  /// the raw request body and the metadata as JSON-encoded query
  /// parameters in a `meta` field. This matches the existing
  /// `/api/imaging/save-fits` flow.
  Future<Response> handleUploadDark(Request request) async {
    _logInfo('[API] POST /api/calibration/darks/upload');

    final contentLength = int.tryParse(request.headers['content-length'] ?? '');
    if (contentLength != null &&
        contentLength > CalibrationHandlers._maxDarkUploadBytes) {
      return jsonTooLarge({
        'error': 'dark_upload_too_large',
        'maxBytes': CalibrationHandlers._maxDarkUploadBytes,
      });
    }

    final metaParam = request.url.queryParameters['meta'];
    if (metaParam == null || metaParam.isEmpty) {
      throw BadRequestError(
        field: 'meta',
        expected: 'url-encoded JSON object',
        message:
            'POST /api/calibration/darks/upload requires a `meta` query '
            'parameter containing the JSON dark metadata',
      );
    }
    Map<String, dynamic> meta;
    try {
      final decoded = jsonDecode(metaParam);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('meta is not a JSON object');
      }
      meta = decoded;
    } on FormatException catch (e) {
      throw BadRequestError(
        field: 'meta',
        expected: 'url-encoded JSON object',
        message: 'Failed to parse `meta` query parameter: ${e.message}',
      );
    }

    final exposureDuration = requireDouble(meta, 'exposureDuration', min: 0);
    final sensorTempC = optionalDouble(meta, 'sensorTempC');
    final gain = optionalInt(meta, 'gain') ?? 0;
    final offset = optionalInt(meta, 'offset') ?? 0;
    final binX = optionalInt(meta, 'binX', min: 1) ?? 1;
    final binY = optionalInt(meta, 'binY', min: 1) ?? 1;
    final frameType = optionalString(meta, 'frameType') ?? 'dark';
    final width = optionalInt(meta, 'width');
    final height = optionalInt(meta, 'height');
    final frameCount = optionalInt(meta, 'frameCount');

    if (frameType != 'dark' && frameType != 'bias') {
      throw BadRequestError(
        field: 'frameType',
        expected: '"dark" or "bias"',
        message: 'frameType must be "dark" or "bias", got "$frameType"',
      );
    }

    final requestedName =
        request.url.queryParameters['fileName'] ?? 'upload.fits';
    final sanitized = _sanitizeDarkFileName(requestedName);
    if (sanitized == null) {
      return jsonBadRequest({
        'error': 'invalid_filename',
        'message':
            'Filename must end in .fits, .fit, or .xisf and contain no '
            'path separators',
      });
    }

    final dir = await _calibrationDarksDir();
    final destination = await _resolveUniquePath(dir, sanitized);

    // Stream the body straight to disk; we track size as we go so a body
    // that lies about its Content-Length still gets truncated.
    final sink = destination.openWrite();
    int bytesWritten = 0;
    bool oversized = false;
    try {
      await for (final chunk in request.read()) {
        bytesWritten += chunk.length;
        if (bytesWritten > CalibrationHandlers._maxDarkUploadBytes) {
          oversized = true;
          break;
        }
        sink.add(chunk);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (oversized) {
      try {
        if (await destination.exists()) {
          await destination.delete();
        }
      } catch (e) {
        _logWarning(
          'Failed to remove oversized dark upload at '
          '${destination.path}: $e',
        );
      }
      return jsonTooLarge({
        'error': 'dark_upload_too_large',
        'maxBytes': CalibrationHandlers._maxDarkUploadBytes,
      });
    }

    if (bytesWritten == 0) {
      try {
        if (await destination.exists()) {
          await destination.delete();
        }
      } on Object catch (e) {
        // Why: best-effort cleanup of a partially-written destination; the
        // BadRequestError thrown immediately below is the surfaced outcome.
        _logger.debug(
          'Dark upload: failed to delete empty destination file: $e',
          source: 'DarkLibraryHandlers',
        );
      }
      throw BadRequestError(
        field: 'body',
        expected: 'FITS payload',
        message: 'Upload body was empty',
      );
    }

    final companion = DarkLibraryCompanion.insert(
      filePath: destination.path,
      exposureTime: exposureDuration,
      temperature: Value(sensorTempC),
      gain: Value(gain),
      offset: Value(offset),
      binX: Value(binX),
      binY: Value(binY),
      frameType: Value(frameType),
      width: Value(width),
      height: Value(height),
      masterFrameCount: Value(frameCount),
    );

    final id = await _database.darkLibraryDao.addEntry(companion);
    final entry = await _database.darkLibraryDao.getEntryById(id);
    if (entry == null) {
      throw HandlerFailure(
        code: 'dark_register_failed',
        message: 'Failed to read back newly-created dark library entry',
      );
    }
    return jsonCreated({
      'dark': await _darkEntryToWire(entry),
      'bytesWritten': bytesWritten,
    });
  }

  /// GET /api/calibration/darks/{id}/download — stream with Range support.
  Future<Response> handleDownloadDark(Request request, String id) async {
    _logInfo('[API] GET /api/calibration/darks/$id/download');
    final iid = _parsePathId(id, 'id');

    final entry = await _database.darkLibraryDao.getEntryById(iid);
    if (entry == null) {
      return jsonNotFound({
        'error': 'dark_not_found',
        'message': 'No dark library entry with id $iid',
      });
    }
    final file = File(entry.filePath);
    if (!await file.exists()) {
      return jsonNotFound({
        'error': 'dark_file_not_found',
        'message': 'On-disk file is missing for dark $iid',
        'filePath': entry.filePath,
      });
    }

    final int fileLength;
    final DateTime mtime;
    try {
      fileLength = await file.length();
      mtime = await file.lastModified();
    } on PathAccessException catch (e) {
      _logWarning('Permission denied reading dark $iid: $e');
      return jsonForbidden({
        'error': 'permission_denied',
        'path': entry.filePath,
      });
    } on FileSystemException catch (e) {
      return jsonInternalServerError({
        'error': 'stat_failed',
        'detail': e.message,
      });
    }

    final fileName = p.basename(entry.filePath);
    final lower = fileName.toLowerCase();
    String contentType;
    if (lower.endsWith('.fits') || lower.endsWith('.fit')) {
      contentType = 'application/fits';
    } else if (lower.endsWith('.xisf')) {
      contentType = 'application/x-xisf';
    } else {
      contentType = 'application/octet-stream';
    }

    final etag = '"dark-$iid-${mtime.millisecondsSinceEpoch}"';
    final rangeHeader = request.headers['range'];
    final ifRange = request.headers['if-range'];
    final ifRangeMatches = ifRange == null || ifRange == etag;
    final shouldHonourRange = rangeHeader != null && ifRangeMatches;

    if (!shouldHonourRange) {
      return attachmentResponse(
        file.openRead(),
        fileName: fileName,
        contentType: contentType,
        contentLength: fileLength,
        headers: {'accept-ranges': 'bytes', 'etag': etag},
      );
    }

    final int rangeStart;
    final int rangeEnd;
    try {
      final parsed = parseRangeHeader(rangeHeader, fileLength);
      rangeStart = parsed.start;
      rangeEnd = parsed.end;
    } on FormatException catch (e) {
      return rangeNotSatisfiableResponse(fileLength, reason: e.message);
    }

    return partialContentResponse(
      file.openRead(rangeStart, rangeEnd + 1),
      start: rangeStart,
      end: rangeEnd,
      totalLength: fileLength,
      contentType: contentType,
      fileName: fileName,
      headers: {'etag': etag},
    );
  }

  /// DELETE /api/calibration/darks/{id}?deleteFile=true
  Future<Response> handleDeleteDark(Request request, String id) async {
    _logInfo('[API] DELETE /api/calibration/darks/$id');
    final iid = _parsePathId(id, 'id');
    final deleteFile =
        request.url.queryParameters['deleteFile']?.toLowerCase() == 'true';

    final entry = await _database.darkLibraryDao.getEntryById(iid);
    if (entry == null) {
      return jsonNotFound({
        'error': 'dark_not_found',
        'message': 'No dark library entry with id $iid',
      });
    }

    bool fileDeleted = false;
    if (deleteFile) {
      try {
        final file = File(entry.filePath);
        if (await file.exists()) {
          await file.delete();
          fileDeleted = true;
        }
      } on PathAccessException catch (e) {
        _logWarning('Permission denied deleting dark $iid file: $e');
        return jsonForbidden({
          'error': 'permission_denied',
          'message': 'Could not delete on-disk dark file',
          'path': entry.filePath,
        });
      } on FileSystemException catch (e) {
        _logWarning('Failed to delete dark $iid file: ${e.message}');
        // The DB row still gets removed below; we surface the file-side
        // failure in the response so the caller can decide whether to
        // clean up manually.
        await _database.darkLibraryDao.deleteEntry(iid);
        return jsonOk({
          'deleted': true,
          'fileDeleted': false,
          'fileError': e.message,
        });
      }
    }

    final rowsAffected = await _database.darkLibraryDao.deleteEntry(iid);
    return jsonOk({'deleted': rowsAffected > 0, 'fileDeleted': fileDeleted});
  }

  /// POST /api/calibration/darks/find-match
  Future<Response> handleFindMatchingDark(Request request) async {
    _logInfo('[API] POST /api/calibration/darks/find-match');
    final payload = await readJsonObject(request);

    final exposureDuration = requireDouble(payload, 'exposureDuration', min: 0);
    final gain = optionalInt(payload, 'gain') ?? 0;
    final offset = optionalInt(payload, 'offset') ?? 0;
    final binX = optionalInt(payload, 'binX', min: 1) ?? 1;
    final binY = optionalInt(payload, 'binY', min: 1) ?? 1;
    final sensorTempC = optionalDouble(payload, 'sensorTempC');
    final frameType = optionalString(payload, 'frameType') ?? 'dark';

    DarkLibraryMatchTolerances tolerances = DarkLibraryMatchTolerances.defaults;
    final tolMap = optionalObject(payload, 'tolerances');
    if (tolMap != null) {
      final exposureRatio = optionalDouble(tolMap, 'exposureSecondsRatio');
      final exposureAbs = optionalDouble(tolMap, 'exposureSeconds');
      final temperatureTol = optionalDouble(tolMap, 'temperatureCelsius');
      double exposureSecs = tolerances.exposureSecs;
      if (exposureAbs != null) {
        exposureSecs = exposureAbs;
      } else if (exposureRatio != null) {
        exposureSecs = exposureDuration * exposureRatio;
      }
      tolerances = DarkLibraryMatchTolerances.validated(
        exposureSecs: exposureSecs,
        temperatureC: temperatureTol ?? tolerances.temperatureC,
      );
    }

    final match = await _database.darkLibraryDao.findBestMatch(
      exposureTime: exposureDuration,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      temperature: sensorTempC,
      tolerances: tolerances,
      frameType: frameType,
    );
    if (match == null) {
      return jsonNotFound({
        'error': 'no_matching_dark',
        'message':
            'No dark library entry matches the requested capture parameters',
      });
    }
    return jsonOk({'dark': await _darkEntryToWire(match)});
  }

  /// POST /api/calibration/match-dark
  ///
  /// Remote-client counterpart to the local `DarkLibraryService.findMatchingDark`
  /// path in `CalibrationService.calibrateFile`. A remote client cannot run the
  /// matcher itself because the dark library (and its FITS files) live on the
  /// host, so it asks the host to run the match and report back the matched
  /// dark's on-host file path. The path is then handed straight to
  /// `POST /api/imaging/calibrate-file`, which reads it host-side.
  ///
  /// Unlike `darks/find-match` (which returns the full wire entry, 404 on miss),
  /// this endpoint always answers 200 with `{matched: <hostPath>|null}` so the
  /// caller can branch on a clean null without treating "no match" as an error.
  ///
  /// The matcher is routed through the same `darkLibraryMatchTolerancesProvider`
  /// the local path and the coverage UI consult, so the host and a co-located
  /// local client agree on what counts as a matching dark.
  Future<Response> handleMatchDark(Request request) async {
    _logInfo('[API] POST /api/calibration/match-dark');
    final payload = await readJsonObject(request);

    final exposureTime = requireDouble(payload, 'exposureTime', min: 0);
    final gain = requireInt(payload, 'gain');
    final offset = optionalInt(payload, 'offset') ?? 0;
    final binX = optionalInt(payload, 'binX', min: 1) ?? 1;
    final binY = optionalInt(payload, 'binY', min: 1) ?? 1;
    final temperature = optionalDouble(payload, 'temperature');

    final darkLibrary = container.read(darkLibraryServiceProvider);
    final tolerances = container.read(darkLibraryMatchTolerancesProvider);

    final match = await darkLibrary.findMatchingDark(
      exposureTime: exposureTime,
      gain: gain,
      offset: offset,
      binX: binX,
      binY: binY,
      temperature: temperature,
      tolerances: tolerances,
    );

    if (match == null) {
      _logInfo('No matching dark in library for remote calibration request');
      return jsonOk({'matched': null});
    }
    _logInfo(
      'Matched dark for remote calibration: ${match.filePath} '
      '(exposure=${match.exposureTime}s, temp=${match.temperature}C)',
    );
    return jsonOk({'matched': match.filePath});
  }

  /// POST /api/calibration/darks/backfill-sizes
  ///
  /// Note: the `dark_library` schema has no `file_size` column, so this
  /// endpoint performs the closest equivalent — a verification pass that
  /// stats every row, returning counts of present/missing/error rows and
  /// the total on-disk byte usage. Mirrors the spirit of the
  /// `captured_images.fileSize` backfill (which DOES update a column).
  Future<Response> handleVerifyDarkSizes(Request request) async {
    _logInfo('[API] POST /api/calibration/darks/backfill-sizes');
    final stats = await _database.darkLibraryDao.verifyOnDiskState(
      logger: _logger,
    );
    return jsonOk({
      'verified': stats['total'],
      'present': stats['present'],
      'missing': stats['missing'],
      'errors': stats['errors'],
      'totalBytes': stats['totalBytes'],
      // For symmetry with /images backfill: no rows are mutated by this
      // endpoint (no file_size column on dark_library), so we surface zero
      // here so clients can use the same code path.
      'updated': 0,
      'skipped': stats['missing'],
    });
  }
}
