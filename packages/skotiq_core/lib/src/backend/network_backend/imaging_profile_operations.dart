part of '../network_backend.dart';

mixin _NetworkBackendImagingProfileOperations on _NetworkBackendTransport {
  @override
  Future<List<EquipmentProfile>> getProfiles() async {
    final response = await _get(ProfileApi.getProfiles);
    return (response['profiles'] as List)
        .map((p) => EquipmentProfile.fromJson(p as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<void> saveProfile(EquipmentProfile profile) =>
      saveProfileFields(profile, fields: null);

  /// Save [profile]; when [fields] is given, ask the host to update only those
  /// fields of its existing row, so edits made elsewhere to the other fields
  /// survive. A host that predates field updates stores the whole profile.
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

  @override
  Future<void> deleteProfile(String profileId) async {
    await _delete(ProfileApi.deleteProfile, path: {'profileId': profileId});
  }

  @override
  Future<void> loadProfile(String profileId) async {
    await _post(ProfileApi.loadProfile, path: {'profileId': profileId});
  }

  /// Set [profileId] as the host's default startup profile (atomically
  /// unsetting the previous default and making this row active). Routes to the
  /// dedicated host endpoint because the generic saveProfile path preserves the
  /// host row's existing `isDefault` and cannot flip the default.
  ///
  /// NetworkBackend-only (not on the abstract ProfileSettingsBackend role) so
  /// FfiBackend/DisconnectedBackend need no implementation.
  Future<void> setDefaultProfileRemote(String profileId) async {
    await _post(ProfileApi.setDefaultProfile, path: {'profileId': profileId});
  }

  /// Clear the host's default startup profile (unset `isDefault` on every
  /// row). Routes to the dedicated host endpoint because saveProfile preserves
  /// the host row's existing `isDefault`. NetworkBackend-only.
  Future<void> clearDefaultProfileRemote() async {
    await _post(ProfileApi.clearDefaultProfile);
  }

  /// Persist [orderedIds] as the host's profile display order. Routes to the
  /// dedicated host endpoint because saveProfile preserves the host row's
  /// existing `sortOrder`. NetworkBackend-only.
  Future<void> reorderProfilesRemote(List<String> orderedIds) async {
    await _post(ProfileApi.reorderProfiles, body: {'profileIds': orderedIds});
  }

  @override
  Future<EquipmentProfile?> getActiveProfile() async {
    final response = await _get(ProfileApi.getActiveProfile);
    if (response['profile'] == null) return null;
    return EquipmentProfile.fromJson(
      response['profile'] as Map<String, dynamic>,
    );
  }

  /// `GET /api/system/disk-space` — the HOST's capture-directory disk
  /// telemetry. Deliberately not part of [SkotiqBackend]: local backends
  /// sample their own filesystem; only remote clients need the wire hop
  /// (the host's capture path does not exist on the phone's filesystem).
  /// Returns `null` when the host has no capture directory configured.
  Future<DiskSpaceInfo?> getHostCaptureDiskSpace() async {
    final json = await _get(SystemApi.diskSpace);
    if (json['configured'] == false) return null;
    return DiskSpaceInfo(
      path: json['path'] as String? ?? '',
      totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
      freeBytes: (json['freeBytes'] as num?)?.toInt() ?? 0,
      sampledAt:
          DateTime.tryParse(json['sampledAt'] as String? ?? '')?.toLocal() ??
          DateTime.now(),
    );
  }

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

  /// The host's `app_settings` key/value rows that are not part of the
  /// [models.AppSettings] wire model, or null when the host predates
  /// `GET /api/settings/store` and answers 404.
  Future<HostSettingsRows?> getSettingsStore() {
    return _retryableRequest(() async {
      final endpoint = _endpointPath(
        ProfileApi.getSettingsStore,
        ApiMethod.get,
      );
      final response = await _sendWithAuthRefresh(
        endpoint: endpoint,
        send: (headers) => _http.get(_apiUri(endpoint), headers: headers),
      );
      if (response.statusCode == HttpStatus.notFound) return null;
      if (response.statusCode != 200) {
        throw _parseErrorResponse(
          response.statusCode,
          response.body,
          'GET',
          endpoint,
        );
      }
      final json = jsonDecode(response.body);
      final settings = json is Map<String, dynamic> ? json['settings'] : null;
      if (settings is! Map) {
        throw StateError(
          'GET /api/settings/store returned no settings object (HTTP 200)',
        );
      }
      final adminAccess = json['adminAccess'];
      return HostSettingsRows(
        settings.map(
          (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
        ),
        adminAccess: adminAccess is bool ? adminAccess : null,
      );
    });
  }

  /// Write [settings] into the host's key/value store and delete [remove].
  Future<void> updateSettingsStore(
    Map<String, String> settings, {
    List<String> remove = const [],
  }) async {
    await _post(
      ProfileApi.updateSettingsStore,
      body: {'settings': settings, if (remove.isNotEmpty) 'remove': remove},
    );
  }

  /// Merge [fields] into the JSON-object rows of the host's key/value store.
  ///
  /// [fallback] carries, for every key in [fields], the whole value this
  /// client would write: a host that predates merging ignores `merge` and
  /// stores it, while a current host ignores it and lays only [fields] over
  /// its own row (or over [base] when it has none). Returns the values the
  /// host stored, or [fallback] when the host did not say.
  Future<Map<String, String>> mergeSettingsStore(
    Map<String, Map<String, Object?>> fields, {
    required Map<String, String> fallback,
    Map<String, Map<String, Object?>> base = const {},
  }) async {
    final response = await _post(
      ProfileApi.updateSettingsStore,
      body: {
        'settings': fallback,
        'merge': fields,
        if (base.isNotEmpty) 'mergeBase': base,
      },
    );
    final merged = response['merged'];
    if (merged is! Map) return fallback;
    return {
      ...fallback,
      for (final entry in merged.entries)
        entry.key.toString(): entry.value?.toString() ?? '',
    };
  }

  /// POST only the [patch] keys of the typed settings document. The host
  /// merges them onto its current settings, so fields this client did not
  /// change keep whatever value the host holds now.
  Future<void> updateSettingsPatchWithCommandId(
    Map<String, dynamic> patch, {
    required String? commandId,
  }) async {
    final extraHeaders = commandId == null
        ? null
        : <String, String>{'X-Skotiq-Command-Id': commandId};
    await _post(
      ProfileApi.updateSettings,
      body: {'settings': patch},
      headers: extraHeaders,
    );
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

  /// Load the imaging host's global meridian-flip defaults.
  ///
  /// These settings drive unattended hardware behavior and therefore belong
  /// to the host, not the phone rendering the settings screen.
  Future<MeridianFlipSettings> getMeridianFlipSettings() async {
    final response = await _get(ProfileApi.getMeridianFlipSettings);
    final raw = response['settings'];
    if (raw is! Map<String, dynamic>) {
      throw const FormatException(
        'GET /api/settings/meridian-flip returned no settings object',
      );
    }
    return MeridianFlipSettings.fromJson(raw);
  }

  /// Replace the imaging host's global meridian-flip defaults.
  Future<void> updateMeridianFlipSettings(MeridianFlipSettings settings) async {
    await _post(
      ProfileApi.updateMeridianFlipSettings,
      body: {'settings': settings.toJson()},
    );
  }

  /// Load the headless/desktop host's Home Assistant discovery and broker
  /// configuration. The returned broker never contains its password.
  Future<HomeAssistantHostSettings> getHomeAssistantHostSettings() async {
    final response = await _get(ProfileApi.getHomeAssistantSettings);
    return HomeAssistantHostSettings.fromJson(response);
  }

  /// Replace the host's Home Assistant discovery and broker configuration.
  ///
  /// Omitting [replacementPassword] preserves the write-only host secret;
  /// passing an empty string explicitly clears it.
  Future<HomeAssistantHostSettings> updateHomeAssistantHostSettings({
    required HomeAssistantDiscoveryConfig config,
    required MqttTransportConfig broker,
    String? replacementPassword,
    bool replacePassword = false,
  }) async {
    final response = await _post(
      ProfileApi.updateHomeAssistantSettings,
      body: {
        'config': config.toJson(),
        'broker': broker.copyWith(clearPassword: true).toJson(),
        if (replacePassword) 'password': replacementPassword ?? '',
      },
    );
    return HomeAssistantHostSettings.fromJson(response);
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

  /// Ask the host to find the best-matching dark in its library for the given
  /// light-frame capture parameters and return that dark's on-host file path.
  ///
  /// A remote client can't run the matcher itself — the dark library and its
  /// FITS files live on the host — so this delegates to
  /// `POST /api/calibration/match-dark`. The returned path is a host-side path
  /// and is meant to be handed straight to [calibrateImageFile], which reads
  /// it host-side. Returns `null` when no library dark matches.
  Future<String?> matchDarkFromLibrary({
    required double exposureTime,
    required int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    double? temperature,
  }) async {
    final response = await _post(
      CalibrationApi.matchDark,
      body: {
        'exposureTime': exposureTime,
        if (gain != null) 'gain': gain,
        if (offset != null) 'offset': offset,
        'binX': binX,
        'binY': binY,
        if (temperature != null) 'temperature': temperature,
      },
    );
    return response['matched'] as String?;
  }

  /// Build a defect map host-side from dark frames.
  ///
  /// A remote client has no local picker over the host filesystem, so it
  /// passes either explicit on-host [darkFramePaths] or a single host
  /// [darkFramesDirectory] for the host to enumerate. Delegates to
  /// `POST /api/calibration/defect-maps/build`; the host runs the same
  /// `DefectMapService.build` the local FFI path uses and returns the
  /// resulting status.
  Future<DefectMapStatus> buildDefectMap({
    required String cameraId,
    required double sensorTemperatureCelsius,
    List<String>? darkFramePaths,
    String? darkFramesDirectory,
  }) async {
    final response = await _post(
      CalibrationApi.buildDefectMap,
      body: {
        'cameraId': cameraId,
        'sensorTemperatureCelsius': sensorTemperatureCelsius,
        if (darkFramePaths != null) 'darkFramePaths': darkFramePaths,
        if (darkFramesDirectory != null)
          'darkFramesDirectory': darkFramesDirectory,
      },
    );
    final status = response['status'] as Map<String, dynamic>;
    return _defectMapStatusFromJson(status);
  }

  /// Query the defect map owned by the imaging host for one exact
  /// camera/sensor/temperature bucket. Null means no map exists.
  Future<DefectMapStatus?> getDefectMapStatus({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
  }) async {
    final response = await _get(
      CalibrationApi.getDefectMapStatus,
      query: {
        'cameraId': cameraId,
        'width': width,
        'height': height,
        'sensorTemperatureCelsius': sensorTemperatureCelsius,
      },
    );
    final status = response['status'];
    if (status == null) return null;
    if (status is! Map<String, dynamic>) {
      throw const FormatException('Malformed remote defect-map status');
    }
    return _defectMapStatusFromJson(status);
  }

  /// Clear one exact host defect-map bucket and disable its apply flag.
  Future<void> clearDefectMap({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
  }) async {
    await _post(
      CalibrationApi.clearDefectMap,
      body: {
        'cameraId': cameraId,
        'width': width,
        'height': height,
        'sensorTemperatureCelsius': sensorTemperatureCelsius,
      },
    );
  }

  /// Push the selected map and correction strategy into the host's live
  /// sequencer runtime. This is distinct from the persisted per-camera apply
  /// flag and must run on the process that owns the executor.
  Future<void> applyDefectMapToSequencer({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
    required bool enabled,
    required DefectMapMethod method,
    required DefectMapKernelSize kernel,
    required bool saveOriginal,
  }) async {
    await _post(
      CalibrationApi.applyDefectMapToSequencer,
      body: {
        'cameraId': cameraId,
        'width': width,
        'height': height,
        'sensorTemperatureCelsius': sensorTemperatureCelsius,
        'enabled': enabled,
        'method': method.wireValue,
        'kernelDiameter': kernel.diameter,
        'saveOriginal': saveOriginal,
      },
    );
  }

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

  /// Toggle whether the host applies the stored defect map to lights at
  /// capture time. Delegates to `POST /api/calibration/defect-maps/apply`.
  Future<void> applyDefectMap({
    required String cameraId,
    required bool applyDuringCapture,
  }) async {
    await _post(
      CalibrationApi.applyDefectMap,
      body: {'cameraId': cameraId, 'applyDuringCapture': applyDuringCapture},
    );
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
    for (var index = 0; index < imagesList.length; index++) {
      final image = _capturedImageFromRow(imagesList[index], index);
      if (!ids.add(image.id)) {
        throw FormatException(
          'sessions/$sessionId/images contains duplicate image id '
          '${image.id}',
        );
      }
      images.add(image);
    }
    return images;
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

  Future<List<Map<String, dynamic>>> getAllImageRows() async {
    final response = await _get(SessionApi.getAllImages);
    return _rowsFromJson<Map<String, dynamic>>(
      response['images'],
      (row) => row,
    );
  }

  Future<List<Map<String, dynamic>>> getStandaloneImageRows() async {
    final response = await _get(SessionApi.getStandaloneImages);
    return _rowsFromJson<Map<String, dynamic>>(
      response['images'],
      (row) => row,
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
      throw _parseErrorResponse(response.statusCode, body, 'GET', endpoint);
    }
    final bytes = await consolidateHttpClientResponseBytes(response);
    if (bytes.isEmpty) {
      throw FormatException('$endpoint returned an empty thumbnail');
    }
    return Uint8List.fromList(bytes);
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
      throw _parseErrorResponse(statusCode, body, 'GET', endpoint);
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
    const currentKeys = {
      'id',
      'filePath',
      'capturedAt',
      'exposureDuration',
      'binX',
      'binY',
      'frameType',
      'fileFormat',
      'starCount',
    };
    const legacyKeys = {
      'image_id',
      'file_path',
      'captured_at',
      'exposure_duration',
      'bin_x',
      'bin_y',
      'frame_type',
      'file_format',
      'star_count',
    };
    final hasCurrent = currentKeys.any(row.containsKey);
    final hasLegacy = legacyKeys.any(row.containsKey);
    final context = 'sessions image row $index';
    if (hasCurrent == hasLegacy) {
      throw FormatException(
        '$context must use exactly one supported image metadata schema',
      );
    }

    final idKey = hasCurrent ? 'id' : 'image_id';
    final pathKey = hasCurrent ? 'filePath' : 'file_path';
    final capturedAtKey = hasCurrent ? 'capturedAt' : 'captured_at';
    final exposureKey = hasCurrent ? 'exposureDuration' : 'exposure_duration';
    final binXKey = hasCurrent ? 'binX' : 'bin_x';
    final binYKey = hasCurrent ? 'binY' : 'bin_y';
    final frameTypeKey = hasCurrent ? 'frameType' : 'frame_type';
    final formatKey = hasCurrent ? 'fileFormat' : 'file_format';
    final starCountKey = hasCurrent ? 'starCount' : 'star_count';

    final id = _requiredImageInt(row, idKey, context, min: 1);
    final path = _requiredImageString(row, pathKey, context);
    final timestamp = _requiredImageInt(row, capturedAtKey, context, min: 1);
    final exposure = _requiredImageDouble(row, exposureKey, context, min: 0);
    final gain = _optionalImageInt(row, 'gain', context, min: 0) ?? 0;
    final offset = _optionalImageInt(row, 'offset', context, min: 0) ?? 0;
    final binX = _requiredImageInt(row, binXKey, context, min: 1);
    final binY = _requiredImageInt(row, binYKey, context, min: 1);
    final filter = _optionalImageString(row, 'filter', context);
    final hfr = _optionalImageDouble(row, 'hfr', context, min: 0);
    final starCount = _optionalImageInt(row, starCountKey, context, min: 0);

    final milliseconds = hasCurrent ? timestamp : timestamp * 1000;
    final DateTime capturedAt;
    try {
      capturedAt = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    } on Object catch (error) {
      throw FormatException('$context.$capturedAtKey is out of range', error);
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
        frameType: _parseFrameType(
          _requiredImageString(row, frameTypeKey, context),
        ),
      ),
      stats: hfr != null || starCount != null
          ? ImageStats(hfr: hfr, starCount: starCount)
          : null,
      format: _parseImageFormat(_requiredImageString(row, formatKey, context)),
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

  FrameType _parseFrameType(String str) {
    switch (str.toLowerCase()) {
      case 'light':
        return FrameType.light;
      case 'dark':
        return FrameType.dark;
      case 'flat':
        return FrameType.flat;
      case 'bias':
        return FrameType.bias;
      case 'darkflat':
      case 'dark_flat':
      case 'dark-flat':
        return FrameType.darkFlat;
      case 'snapshot':
        return FrameType.snapshot;
      default:
        throw FormatException('Unknown captured-image frame type: $str');
    }
  }

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
