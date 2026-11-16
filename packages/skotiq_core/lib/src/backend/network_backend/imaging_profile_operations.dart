part of '../network_backend.dart';

mixin _NetworkBackendImagingProfileOperations on NetworkBackendTransport {
  @override
  Future<models.AppSettings> getSettings() async {
    final json = await _get(ProfileApi.getSettings);
    final settingsJson = json['settings'];
    if (settingsJson is! Map<String, dynamic>) {
      throw StateError(
        'GET /api/settings returned no settings object (HTTP 200)',
      );
    }
    return models.AppSettings.fromJson(settingsJson);
  }

  @override
  Future<void> updateSettings(models.AppSettings settings) async {
    // Forward through the dedicated overload so
    // origin-filtering callers can stamp a command id without changing
    // the public interface of SkotiqBackend.
    return updateSettingsWithCommandId(settings, commandId: null);
  }

  /// Variant of [updateSettings] that stamps the
  /// outgoing POST with an `X-Skotiq-Command-Id` header so the
  /// `settings.changed` events that come back over the WS carry the
  /// `correlatingCommandId` and the calling client can ignore its own
  /// echo. Callers track the same id locally; un-paired clients can
  /// continue to call [updateSettings] and accept the echo as a no-op
  /// (the diff against in-memory state will already be empty).
  Future<void> updateSettingsWithCommandId(
    models.AppSettings settings, {
    required String? commandId,
  }) async {
    final extraHeaders = commandId == null
        ? null
        : <String, String>{'X-Skotiq-Command-Id': commandId};
    await _post(
      ProfileApi.updateSettings,
      body: {'settings': settings.toJson()},
      headers: extraHeaders,
    );
  }

  @override
  Future<models.ObserverLocation?> getLocation() async {
    final json = await _get(ProfileApi.getLocation);
    if (json['location'] == null) return null;
    return models.ObserverLocation.fromJson(
      json['location'] as Map<String, dynamic>,
    );
  }

  @override
  Future<void> setLocation(models.ObserverLocation? location) async {
    await _post(ProfileApi.setLocation, body: {'location': location?.toJson()});
  }

  @override
  Future<List<StarCrop>> getStarCropsFromLastImage(
    String deviceId, {
    int maxCrops = 5,
  }) async {
    final response = await _get(
      ImagingApi.getStarCrops,
      query: {'deviceId': deviceId, 'maxCrops': maxCrops},
    );
    final crops = response['crops'] as List<dynamic>;
    return crops
        .map((crop) => StarCrop.fromJson(crop as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<FitsReadResult> readFitsFile({required String filePath}) {
    // Host-local: a full FITS decode reads the host filesystem and returns the
    // entire display buffer + histogram. Remote clients fetch only the specific
    // fields they need from the host instead (e.g. dimensions via
    // [getFitsDimensions]); there is no endpoint that streams a decoded
    // FitsReadResult, so this is unsupported over the network.
    throw UnsupportedError(
      'readFitsFile is host-local: a remote client cannot decode a FITS file '
      'on the host filesystem. Use getFitsDimensions for dimensions, or run '
      'this on the local backend.',
    );
  }

  @override
  Uint8List autoStretchImage({
    required int width,
    required int height,
    required List<int> data,
  }) {
    // Host-local: this stretches a raw u16 pixel buffer in process. The host
    // never accepts client pixel uploads (POST /api/imaging/stretch rejects
    // them), and a remote client receives already-stretched RGBA from the
    // host, so there is nothing to route to.
    throw UnsupportedError(
      'autoStretchImage is host-local: raw pixel buffers are not transferred '
      'over the network. Remote clients render the host-stretched RGBA.',
    );
  }

  @override
  Future<void> renderFinishingPreview({
    required String inputFits,
    required String outputPng,
  }) {
    // Host-local: both the input FITS and the output PNG live on the machine
    // that owns the finishing artifacts. There is no endpoint to render a
    // host-side preview on a remote client's behalf.
    throw UnsupportedError(
      'renderFinishingPreview is host-local: the finishing FITS and its '
      'preview PNG live on the host filesystem and cannot be rendered from a '
      'remote client.',
    );
  }

  @override
  Stream<Map<String, dynamic>> get polarAlignmentEvents =>
      _polarAlignController.stream;

  @override
  Future<void> startPolarAlignment({
    required double exposureTime,
    required double stepSize,
    required int binning,
    required bool isNorth,
    required bool manualRotation,
    required bool rotateEast,
    int? gain,
    int? offset,
    double? solveTimeout,
    bool? startFromCurrent,
    double? autoCompleteThreshold,
  }) async {
    await _post(
      SessionApi.startPolarAlignment,
      body: {
        'exposure_time': exposureTime,
        'step_size': stepSize,
        'binning': binning,
        'is_north': isNorth,
        'manual_rotation': manualRotation,
        'rotate_east': rotateEast,
        if (gain != null) 'gain': gain,
        if (offset != null) 'offset': offset,
        if (solveTimeout != null) 'solve_timeout': solveTimeout,
        if (startFromCurrent != null) 'start_from_current': startFromCurrent,
        if (autoCompleteThreshold != null)
          'auto_complete_threshold': autoCompleteThreshold,
      },
    );
  }

  @override
  Future<void> stopPolarAlignment() async {
    await _post(SessionApi.stopPolarAlignment, body: {});
  }

  @override
  Future<void> startAllSkyPolarAlignment({
    required double exposureTime,
    required double solveTimeout,
    required int binning,
    required bool isNorth,
    required double acceptanceThresholdArcsec,
    required double iterationCadenceSecs,
    int? gain,
    int? offset,
  }) async {
    await _post(
      SessionApi.startAllSkyPolarAlignment,
      body: {
        'exposure_time': exposureTime,
        'solve_timeout': solveTimeout,
        'binning': binning,
        'is_north': isNorth,
        'acceptance_threshold_arcsec': acceptanceThresholdArcsec,
        'iteration_cadence_secs': iterationCadenceSecs,
        if (gain != null) 'gain': gain,
        if (offset != null) 'offset': offset,
      },
    );
  }

  @override
  Future<List<CapturedImage>> getSessionImages(int sessionId) async {
    if (sessionId <= 0) {
      throw ArgumentError.value(sessionId, 'sessionId', 'must be positive');
    }
    final imagesList = await getSessionImageRows(sessionId);
    final images = <CapturedImage>[];
    final ids = <String>{};
    final unreadable = <String>[];
    for (var index = 0; index < imagesList.length; index++) {
      final CapturedImage image;
      try {
        image = _capturedImageFromRow(imagesList[index], index);
      } on FormatException catch (error) {
        // One old or odd row must not hide the rest of the session.
        unreadable.add(error.message);
        continue;
      }
      if (!ids.add(image.id)) {
        throw FormatException(
          'sessions/$sessionId/images contains duplicate image id '
          '${image.id}',
        );
      }
      images.add(image);
    }
    if (unreadable.isNotEmpty) {
      Log.warning(
        'Session $sessionId: ${unreadable.length} of ${imagesList.length} '
        'frames on the host could not be read here and are not listed '
        '(${unreadable.first}). The host lists them.',
        source: 'NetworkBackend',
      );
    }
    return images;
  }

  @override
  Future<void> downloadImage(
    int imageId,
    String localPath, {
    void Function(double)? onProgress,
  }) async {
    if (imageId <= 0) {
      throw ArgumentError.value(imageId, 'imageId', 'must be positive');
    }
    final file = File(localPath);
    await file.parent.create(recursive: true);
    final metadataFile = File('$localPath.skotiq-download');
    await _downloadImageAttempt(
      imageId: imageId,
      file: file,
      metadataFile: metadataFile,
      onProgress: onProgress,
      mayResetRange: true,
    );
  }

  Future<void> _downloadImageAttempt({
    required int imageId,
    required File file,
    required File metadataFile,
    required void Function(double)? onProgress,
    required bool mayResetRange,
  }) async {
    final endpoint = _endpointPath(SessionApi.downloadImage, ApiMethod.get, {
      'imageId': imageId,
    });
    var resumeOffset = 0;
    _ImageDownloadMetadata? metadata;

    if (await file.exists()) {
      try {
        resumeOffset = await file.length();
      } on FileSystemException catch (error) {
        throw IoException(
          message: 'Failed to stat partial download at ${file.path}: $error',
          userMessage: 'Could not read the partially downloaded file',
        );
      }
      metadata = await _readImageDownloadMetadata(metadataFile);
      final canResume =
          resumeOffset > 0 &&
          metadata != null &&
          metadata.imageId == imageId &&
          resumeOffset <= metadata.totalLength;
      if (!canResume) {
        await _deleteIfPresent(file);
        await _deleteIfPresent(metadataFile);
        resumeOffset = 0;
        metadata = null;
      } else if (resumeOffset == metadata.totalLength) {
        await _deleteIfPresent(metadataFile);
        onProgress?.call(1);
        return;
      }
    } else {
      await _deleteIfPresent(metadataFile);
    }

    final headers = <String, String>{};
    if (resumeOffset > 0) {
      headers[HttpHeaders.rangeHeader] = 'bytes=$resumeOffset-';
      headers[HttpHeaders.ifRangeHeader] = metadata!.etag;
    }
    final response = await _openRawGetWithAuthRefresh(
      endpoint,
      extraHeaders: headers,
    );
    final statusCode = response.statusCode;

    if (statusCode == HttpStatus.requestedRangeNotSatisfiable &&
        resumeOffset > 0 &&
        mayResetRange) {
      await response.drain<void>();
      await _deleteIfPresent(file);
      await _deleteIfPresent(metadataFile);
      return _downloadImageAttempt(
        imageId: imageId,
        file: file,
        metadataFile: metadataFile,
        onProgress: onProgress,
        mayResetRange: false,
      );
    }
    if (statusCode != HttpStatus.ok &&
        statusCode != HttpStatus.partialContent) {
      final body = await response.transform(utf8.decoder).join();
      throw _errorFromResponse(statusCode, body, 'GET', endpoint);
    }

    final contentRange = response.headers.value(HttpHeaders.contentRangeHeader);
    final etag = response.headers.value(HttpHeaders.etagHeader)?.trim();
    final bool isPartial;
    final int totalLength;
    final int expectedBodyLength;

    if (statusCode == HttpStatus.partialContent) {
      if (resumeOffset == 0 || metadata == null) {
        await response.drain<void>();
        throw FormatException('$endpoint returned unsolicited partial content');
      }
      final range = _parseImageContentRange(contentRange, endpoint);
      if (range.start != resumeOffset ||
          range.end < range.start ||
          range.end >= range.total ||
          range.total != metadata.totalLength) {
        await response.drain<void>();
        throw FormatException(
          '$endpoint returned a Content-Range inconsistent with the partial '
          'file',
        );
      }
      expectedBodyLength = range.end - range.start + 1;
      if (response.contentLength != expectedBodyLength) {
        await response.drain<void>();
        throw FormatException(
          '$endpoint Content-Length does not match Content-Range',
        );
      }
      if (etag == null || etag.isEmpty || etag != metadata.etag) {
        await response.drain<void>();
        throw FormatException('$endpoint changed ETag during resume');
      }
      isPartial = true;
      totalLength = range.total;
    } else {
      if (contentRange != null) {
        await response.drain<void>();
        throw FormatException('$endpoint returned Content-Range with HTTP 200');
      }
      if (response.contentLength <= 0) {
        await response.drain<void>();
        throw FormatException('$endpoint omitted a positive Content-Length');
      }
      isPartial = false;
      totalLength = response.contentLength;
      expectedBodyLength = totalLength;
      resumeOffset = 0;
      metadata = null;
    }

    final resumable = etag != null && etag.isNotEmpty;
    if (resumable) {
      await _writeImageDownloadMetadata(
        metadataFile,
        _ImageDownloadMetadata(
          imageId: imageId,
          etag: etag,
          totalLength: totalLength,
        ),
      );
    } else {
      await _deleteIfPresent(metadataFile);
    }

    final sink = file.openWrite(
      mode: isPartial ? FileMode.append : FileMode.write,
    );
    var bytesReceived = resumeOffset;
    var bodyBytes = 0;
    Object? streamError;
    StackTrace? streamStack;
    try {
      await for (final chunk in response) {
        if (bodyBytes + chunk.length > expectedBodyLength ||
            bytesReceived + chunk.length > totalLength) {
          throw FormatException('$endpoint returned more bytes than declared');
        }
        sink.add(chunk);
        bodyBytes += chunk.length;
        bytesReceived += chunk.length;
        onProgress?.call(bytesReceived / totalLength);
      }
    } catch (error, stack) {
      streamError = error;
      streamStack = stack;
    } finally {
      await sink.close();
    }

    final exactLength = await file.length();
    final complete =
        streamError == null &&
        bodyBytes == expectedBodyLength &&
        bytesReceived == totalLength &&
        exactLength == totalLength;
    if (!complete) {
      final corrupt =
          bodyBytes > expectedBodyLength ||
          bytesReceived > totalLength ||
          exactLength > totalLength;
      if (corrupt || !resumable || exactLength == 0) {
        await _deleteIfPresent(file);
        await _deleteIfPresent(metadataFile);
      }
      if (streamError != null) {
        Error.throwWithStackTrace(streamError, streamStack!);
      }
      throw IoException(
        message: '$endpoint ended at $exactLength bytes; expected $totalLength',
        userMessage: 'The image download was incomplete and can be resumed',
      );
    }

    await _deleteIfPresent(metadataFile);
    onProgress?.call(1);
    Log.info(
      '[NetworkBackend] Downloaded image $imageId to ${file.path} '
      '($bytesReceived bytes${isPartial ? ', resumed' : ''})',
      source: 'NetworkBackend',
    );
  }

  Future<_ImageDownloadMetadata?> _readImageDownloadMetadata(File file) async {
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic>) return null;
      final imageId = value['imageId'];
      final etag = value['etag'];
      final totalLength = value['totalLength'];
      if (imageId is! int ||
          imageId <= 0 ||
          etag is! String ||
          etag.isEmpty ||
          totalLength is! int ||
          totalLength <= 0) {
        return null;
      }
      return _ImageDownloadMetadata(
        imageId: imageId,
        etag: etag,
        totalLength: totalLength,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _writeImageDownloadMetadata(
    File file,
    _ImageDownloadMetadata metadata,
  ) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(metadata.toJson()), flush: true);
    await _deleteIfPresent(file);
    await temporary.rename(file.path);
  }

  Future<void> _deleteIfPresent(File file) async {
    if (await file.exists()) await file.delete();
  }

  ({int start, int end, int total}) _parseImageContentRange(
    String? value,
    String endpoint,
  ) {
    if (value == null) {
      throw FormatException('$endpoint omitted Content-Range for HTTP 206');
    }
    final match = RegExp(
      r'^bytes ([0-9]+)-([0-9]+)/([0-9]+)$',
    ).firstMatch(value);
    if (match == null) {
      throw FormatException('$endpoint returned malformed Content-Range');
    }
    return (
      start: int.parse(match.group(1)!),
      end: int.parse(match.group(2)!),
      total: int.parse(match.group(3)!),
    );
  }

  CapturedImage _capturedImageFromRow(Map<String, dynamic> row, int index) {
    final context = 'sessions image row $index';
    final id = _requiredImageInt(row, 'id', context, min: 1);
    final path = _requiredImageString(row, 'filePath', context);
    final timestamp = _requiredImageInt(row, 'capturedAt', context, min: 1);
    final exposure = _requiredImageDouble(
      row,
      'exposureDuration',
      context,
      min: 0,
    );
    final gain = _optionalImageInt(row, 'gain', context, min: 0) ?? 0;
    final offset = _optionalImageInt(row, 'offset', context, min: 0) ?? 0;
    final binX = _requiredImageInt(row, 'binX', context, min: 1);
    final binY = _requiredImageInt(row, 'binY', context, min: 1);
    final filter = _optionalImageString(row, 'filter', context);
    final hfr = _optionalImageDouble(row, 'hfr', context, min: 0);
    final starCount = _optionalImageInt(row, 'starCount', context, min: 0);

    final DateTime capturedAt;
    try {
      capturedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    } on Object catch (error) {
      throw FormatException('$context.capturedAt is out of range', error);
    }

    return CapturedImage(
      id: id.toString(),
      filePath: path,
      capturedAt: capturedAt,
      settings: ExposureSettings(
        exposureTime: exposure,
        gain: gain,
        offset: offset,
        binningX: binX,
        binningY: binY,
        filter: filter,
        frameType: _recordedFrameType(
          _requiredImageString(row, 'frameType', context),
        ),
      ),
      stats: hfr != null || starCount != null
          ? ImageStats(hfr: hfr, starCount: starCount)
          : null,
      format: _parseImageFormat(
        _requiredImageString(row, 'fileFormat', context),
      ),
    );
  }

  int _requiredImageInt(
    Map<String, dynamic> row,
    String key,
    String context, {
    required int min,
  }) {
    if (!row.containsKey(key)) {
      throw FormatException('$context is missing $key');
    }
    final value = row[key];
    if (value is! num || !value.isFinite || value != value.truncateToDouble()) {
      throw FormatException('$context.$key must be an integer');
    }
    final result = value.toInt();
    if (result < min) {
      throw FormatException('$context.$key must be at least $min');
    }
    return result;
  }

  int? _optionalImageInt(
    Map<String, dynamic> row,
    String key,
    String context, {
    required int min,
  }) {
    if (!row.containsKey(key) || row[key] == null) return null;
    return _requiredImageInt(row, key, context, min: min);
  }

  double _requiredImageDouble(
    Map<String, dynamic> row,
    String key,
    String context, {
    required double min,
  }) {
    if (!row.containsKey(key)) {
      throw FormatException('$context is missing $key');
    }
    final value = row[key];
    if (value is! num || !value.isFinite || value < min) {
      throw FormatException('$context.$key must be finite and at least $min');
    }
    return value.toDouble();
  }

  double? _optionalImageDouble(
    Map<String, dynamic> row,
    String key,
    String context, {
    required double min,
  }) {
    if (!row.containsKey(key) || row[key] == null) return null;
    return _requiredImageDouble(row, key, context, min: min);
  }

  String _requiredImageString(
    Map<String, dynamic> row,
    String key,
    String context,
  ) {
    final value = row[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$context.$key must be a non-empty string');
    }
    return value;
  }

  String? _optionalImageString(
    Map<String, dynamic> row,
    String key,
    String context,
  ) {
    if (!row.containsKey(key) || row[key] == null) return null;
    return _requiredImageString(row, key, context);
  }

  FrameType _recordedFrameType(String record) =>
      FrameType.fromRecord(record) ??
      (throw FormatException('Unknown captured-image frame type: $record'));

  ImageFileFormat _parseImageFormat(String str) =>
      ImageFileFormat.fromRecord(str) ??
      (throw FormatException('Unknown captured-image file format: $str'));

  /// The host reconnects its own devices; a linked client reconnects none
  /// of them (see `DeviceReconnectCoordinator`), so nothing here is native.
  @override
  Set<DeviceType> get nativeReconnectedDeviceTypes => const {};

  @override
  Future<(int, bool)> getDeviceHealth(String deviceId) async {
    final response = await _get(
      EquipmentApi.getDeviceHealth,
      path: {'deviceId': deviceId},
    );
    final lastComm = response['last_successful_comm'] as int;
    final isHealthy = response['is_healthy'] as bool;
    return (lastComm, isHealthy);
  }

  @override
  Future<List<int>> getLastRawImageData(String deviceId) async {
    return _retryableRequest(() async {
      final endpoint = _endpointPath(
        ImagingApi.getLastRawImageData,
        ApiMethod.get,
      );
      final uri = _apiUri(endpoint, {'deviceId': deviceId});
      final response = await _sendWithAuthRefresh(
        endpoint: endpoint,
        send: (headers) => _http.get(uri, headers: headers),
      );

      if (_isTransientStatusCode(response.statusCode)) {
        throw Exception(
          'HTTP ${response.statusCode}: Transient failure for GET $endpoint',
        );
      }

      if (response.statusCode != 200) {
        throw IoException(
          message:
              'HTTP ${response.statusCode}: Failed to GET imaging/raw-data',
          userMessage: 'Failed to retrieve the raw image data',
        );
      }

      // The host contract is a packed little-endian u16 stream. Decode it
      // back to pixel samples here; returning the transport bytes directly
      // silently turns every 16-bit pixel into two unrelated 8-bit values.
      final bytes = response.bodyBytes;
      if (bytes.length.isOdd) {
        throw IoException(
          message:
              'Malformed raw image payload: expected an even byte count, '
              'received ${bytes.length}',
          userMessage: 'The host returned malformed raw image data',
        );
      }
      final byteData = ByteData.sublistView(bytes);
      return List<int>.generate(
        bytes.length ~/ Uint16List.bytesPerElement,
        (index) => byteData.getUint16(
          index * Uint16List.bytesPerElement,
          Endian.little,
        ),
        growable: false,
      );
    });
  }

  @override
  Future<void> updateFrameCards(
    String filePath,
    List<FitsKeywordWrite> cards,
  ) async {
    throw UnsupportedError(
      'Frame metadata is written on the host that keeps the frame.',
    );
  }

  @override
  Future<String> saveFitsFromLastCapture({
    required String deviceId,
    required String filePath,
    required FitsWriteHeader headerData,
    bool keepCameraFile = false,
  }) => _saveFromLastCapture({
    'deviceId': deviceId,
    'filePath': filePath,
    'headerData': headerData.toJson(),
    'keepCameraFile': keepCameraFile,
  });

  @override
  Future<String> saveScratchFrameFromLastCapture({
    required String deviceId,
    required String name,
    required FitsWriteHeader headerData,
  }) => _saveFromLastCapture({
    'deviceId': deviceId,
    'scratchName': name,
    'headerData': headerData.toJson(),
  });

  /// The host saves the frame its camera still holds; no pixels travel.
  Future<String> _saveFromLastCapture(Map<String, Object?> body) {
    return _retryableRequest(() async {
      final endpoint = _endpointPath(
        ImagingApi.saveFitsFromLastCapture,
        ApiMethod.post,
      );
      final uri = _apiUri(endpoint);

      final request = await _httpClient.postUrl(uri);
      request.headers.contentType = ContentType.json;

      final headers = _addAuthHeaders({}, endpoint: endpoint);
      headers.forEach((key, value) {
        request.headers.set(key, value);
      });

      request.write(jsonEncode(body));

      final response = await request.close();

      if (_isTransientStatusCode(response.statusCode)) {
        throw Exception(
          'HTTP ${response.statusCode}: Transient failure for POST imaging/save-fits-from-capture',
        );
      }

      if (response.statusCode != 200) {
        throw IoException(
          message:
              'HTTP ${response.statusCode}: Failed to POST imaging/save-fits-from-capture',
          userMessage: 'Failed to save the FITS file on the server',
        );
      }

      final reply = jsonDecode(await response.transform(utf8.decoder).join());
      final saved = reply is Map ? reply['path'] : null;
      if (saved is! String || saved.isEmpty) {
        throw const IoException(
          message: 'imaging/save-fits-from-capture returned no saved path',
          userMessage: 'The host saved the frame but did not say where',
        );
      }
      return saved;
    });
  }

  @override
  Future<void> clearDeviceImage(String deviceId) async {
    await _delete(ImagingApi.clearDeviceImage, path: {'deviceId': deviceId});
  }

  @override
  Future<void> calibrateImageFile({
    required String lightPath,
    String? darkPath,
    String? flatPath,
    String? biasPath,
    required String outputPath,
  }) async {
    await _post(
      ImagingApi.calibrateImageFile,
      body: {
        'lightPath': lightPath,
        if (darkPath != null) 'darkPath': darkPath,
        if (flatPath != null) 'flatPath': flatPath,
        if (biasPath != null) 'biasPath': biasPath,
        'outputPath': outputPath,
      },
    );
  }

  @override
  Future<Uint8List> getImageThumbnail(int imageId) async {
    if (imageId <= 0) {
      throw ArgumentError.value(imageId, 'imageId', 'must be positive');
    }
    final endpoint = _endpointPath(
      SessionApi.getImageThumbnail,
      ApiMethod.get,
      {'imageId': imageId},
    );
    final response = await _openRawGetWithAuthRefresh(endpoint);
    if (response.statusCode != HttpStatus.ok) {
      final body = await response.transform(utf8.decoder).join();
      throw _errorFromResponse(response.statusCode, body, 'GET', endpoint);
    }
    final bytes = await consolidateHttpClientResponseBytes(response);
    if (bytes.isEmpty) {
      throw FormatException('$endpoint returned an empty thumbnail');
    }
    return Uint8List.fromList(bytes);
  }

  @override
  Future<void> loadProfile(String profileId) async {
    await _post(ProfileApi.loadProfile, path: {'profileId': profileId});
  }

  @override
  Future<void> deleteProfile(String profileId) async {
    await _delete(ProfileApi.deleteProfile, path: {'profileId': profileId});
  }

  @override
  Future<void> saveProfile(EquipmentProfile profile) =>
      saveProfileFields(profile, fields: null);

  @override
  Future<EquipmentProfile?> getActiveProfile() async {
    final response = await _get(ProfileApi.getActiveProfile);
    if (response['profile'] == null) return null;
    return EquipmentProfile.fromJson(
      response['profile'] as Map<String, dynamic>,
    );
  }

  @override
  Future<List<EquipmentProfile>> getProfiles() async {
    final response = await _get(ProfileApi.getProfiles);
    return (response['profiles'] as List)
        .map((p) => EquipmentProfile.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  Future<List<Map<String, dynamic>>> getSessionImageRows(int sessionId) async {
    if (sessionId <= 0) {
      throw ArgumentError.value(sessionId, 'sessionId', 'must be positive');
    }
    final response = await _get(
      SessionApi.getSessionImages,
      path: {'sessionId': sessionId},
    );
    return _rowsFromJson<Map<String, dynamic>>(
      response['images'],
      (row) => row,
    );
  }

  /// Save [profile]; when [fields] is given, ask the host to update only those
  /// fields of its existing row, so edits made elsewhere to the other fields
  /// survive.
  Future<void> saveProfileFields(
    EquipmentProfile profile, {
    required Set<String>? fields,
  }) async {
    _lastSavedProfileId = null;
    final response = await _post(
      ProfileApi.saveProfile,
      body: {
        'profile': profile.toJson(),
        if (fields != null) 'fields': fields.toList()..sort(),
      },
    );
    final rawId = response['id'];
    final id = rawId?.toString();
    if (id == null || id.isEmpty || (int.tryParse(id) ?? 0) <= 0) {
      throw const FormatException(
        'Profile save response did not contain a valid positive id',
      );
    }
    _lastSavedProfileId = id;
  }
}

class _ImageDownloadMetadata {
  final int imageId;
  final String etag;
  final int totalLength;

  const _ImageDownloadMetadata({
    required this.imageId,
    required this.etag,
    required this.totalLength,
  });

  Map<String, Object> toJson() => {
    'imageId': imageId,
    'etag': etag,
    'totalLength': totalLength,
  };
}

extension _NetworkBackendImagingProfileOperationsHelpers
    on NetworkBackendTransport {
  DefectMapStatus _defectMapStatusFromJson(Map<String, dynamic> status) {
    return DefectMapStatus(
      cameraId: status['cameraId'] as String,
      width: (status['width'] as num).toInt(),
      height: (status['height'] as num).toInt(),
      temperatureBucket: DefectMapTemperatureBucket(
        (status['temperatureBucketDecicelsius'] as num).toInt(),
      ),
      defectivePixelCount: (status['defectivePixelCount'] as num).toInt(),
      lastRebuiltUnixSeconds: (status['lastRebuiltUnixSeconds'] as num).toInt(),
      applyDuringCapture: status['applyDuringCapture'] as bool,
      storedOnDisk: status['storedOnDisk'] as bool,
    );
  }
}
