part of '../framing_provider.dart';

extension _FramingSurveyOperations on FramingNotifier {
  /// Load the survey cutout for the current target, preferring the on-disk
  /// cache, then Aladin HiPS2FITS, then NASA SkyView.
  ///
  /// A cached snapshot is served only when both the image file *and* its FOV
  /// companion sidecar ([_fovSidecarPath]) are present: without the stored FOV
  /// the [FramingPlateScale] registration linkage cannot be rebuilt, so the
  /// entry is a MISS and the fetch goes to the network rather than serving a
  /// scale-less image. Every successful load pairs the decoded image with the
  /// requested FOV into that plate scale, which is what the framing painters
  /// and gesture handlers project through. When cache and both endpoints fail,
  /// the surfaced [FramingState.imageError] stands.
  ///
  /// [canvasWidthLogicalPx], when supplied, sizes the requested cutout's pixel
  /// resolution to the canvas so wide displays get sharp imagery (see
  /// [_requestPixelWidthFor]); when omitted the last-known canvas width — or the
  /// default — is used. The angular field of view is independent of this and is
  /// resolved from the target + equipment via [_computeRequestFov].
  Future<void> _loadSurveyImage({
    required Object token,
    double? canvasWidthLogicalPx,
  }) async {
    if (_currentState.target == null) return;

    _currentState = _currentState.copyWith(
      isLoadingImage: true,
      imageError: null,
    );

    final target = _currentState.target!;
    final source = _currentState.surveySource;
    final effectiveCanvasWidth = canvasWidthLogicalPx ?? _cutoutCanvasWidthPx;
    if (effectiveCanvasWidth != null && effectiveCanvasWidth > 0) {
      _cutoutCanvasWidthPx = effectiveCanvasWidth;
    }
    final requestPixelWidth = _requestPixelWidthFor(effectiveCanvasWidth);

    try {
      final (requestWidth, requestHeight) = await _computeRequestFov();
      if (!_isCurrentSurveyRequest(token, target, source)) return;

      // Offline-first: serve a pinned cache entry when available.
      final served = await _tryServeFromCache(
        token: token,
        target: target,
        raHours: target.raHours,
        decDegrees: target.decDegrees,
        source: source,
      );
      if (!_isCurrentSurveyRequest(token, target, source)) return;
      if (served) return;

      // Network: Aladin HiPS2FITS primary, NASA SkyView fallback.
      final url = _buildAladinUrl(
        target.raDegrees,
        target.decDegrees,
        requestWidth,
        requestHeight,
        source,
        requestPixelWidth,
      );

      final client = _ref.read(framingSurveyHttpClientFactoryProvider)();
      try {
        http.Response? response;
        try {
          response = await client
              .get(Uri.parse(url))
              .timeout(
                FramingNotifier._surveyImageTimeout,
                onTimeout: () => throw TimeoutException(
                  'Aladin survey image fetch timed out',
                  FramingNotifier._surveyImageTimeout,
                ),
              );
        } catch (e) {
          developer.log(
            'FramingProvider: Aladin survey fetch failed, trying SkyView: $e',
            name: 'FramingProvider',
            level: 900,
            error: e,
          );
        }
        if (!_isCurrentSurveyRequest(token, target, source)) return;

        if (response != null && response.statusCode == 200) {
          await _applyFetchedImage(
            token: token,
            target: target,
            bytes: response.bodyBytes,
            raHours: target.raHours,
            decDegrees: target.decDegrees,
            source: source,
            requestWidth: requestWidth,
            requestHeight: requestHeight,
          );
        } else {
          // Fallback to SkyView
          final skyViewUrl = _buildSkyViewUrl(
            target.raDegrees,
            target.decDegrees,
            requestWidth,
            requestHeight,
            source,
            requestPixelWidth,
          );

          final skyViewResponse = await client
              .get(Uri.parse(skyViewUrl))
              .timeout(
                FramingNotifier._surveyImageTimeout,
                onTimeout: () => throw TimeoutException(
                  'SkyView survey image fetch timed out',
                  FramingNotifier._surveyImageTimeout,
                ),
              );

          if (skyViewResponse.statusCode == 200) {
            await _applyFetchedImage(
              token: token,
              target: target,
              bytes: skyViewResponse.bodyBytes,
              raHours: target.raHours,
              decDegrees: target.decDegrees,
              source: source,
              requestWidth: requestWidth,
              requestHeight: requestHeight,
            );
          } else {
            if (!_isCurrentSurveyRequest(token, target, source)) return;
            _currentState = _currentState.copyWith(
              isLoadingImage: false,
              imageError: 'Failed to load survey image',
            );
          }
        }
      } finally {
        client.close();
      }
    } on TimeoutException catch (e) {
      if (!_isCurrentSurveyRequest(token, target, source)) return;
      _currentState = _currentState.copyWith(
        isLoadingImage: false,
        imageError: 'Survey image fetch timed out - retry?',
      );
      developer.log(
        'FramingProvider: ${e.message}',
        name: 'FramingProvider',
        level: 900,
        error: e,
      );
    } catch (e) {
      if (!_isCurrentSurveyRequest(token, target, source)) return;
      _currentState = _currentState.copyWith(
        isLoadingImage: false,
        imageError: 'Error: ${e.toString()}',
      );
    }
  }

  /// Resolve the angular field of view (width, height) in degrees to request
  /// for the current target and equipment configuration.
  Future<(double, double)> _computeRequestFov() async {
    final equipmentFov = await _getCurrentFOV();
    final previewFov = _currentState.previewFovDegrees;

    if (equipmentFov != null) {
      final equipmentWidth = equipmentFov.$1;
      final equipmentHeight = equipmentFov.$2;

      if (previewFov > equipmentWidth) {
        // User wants to see more context - use preview FOV.
        return (previewFov, previewFov * (equipmentHeight / equipmentWidth));
      }
      // Use equipment FOV with 2.5x context.
      return (equipmentWidth * 2.5, equipmentHeight * 2.5);
    }

    // No equipment - use preview FOV at the default 4:3 aspect.
    return (previewFov, previewFov * 0.75);
  }

  /// Decode [bytes], publish the image plus its [FramingPlateScale], and record
  /// the requested FOV alongside any pinned cache entry so a future offline load
  /// can reconstruct the same registration linkage.
  Future<void> _applyFetchedImage({
    required Object token,
    required FramingTarget target,
    required Uint8List bytes,
    required double raHours,
    required double decDegrees,
    required SurveySource source,
    required double requestWidth,
    required double requestHeight,
  }) async {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromList(bytes, completer.complete);
    final image = await completer.future;

    // Persist the request FOV into the cache metadata sidecar (when a pinned
    // snapshot exists) so offline-first can rebuild the plate scale without a
    // network round-trip.
    await _recordRequestFov(
      raHours: raHours,
      decDegrees: decDegrees,
      source: source,
      fovWidthDeg: requestWidth,
      fovHeightDeg: requestHeight,
    );

    if (!_isCurrentSurveyRequest(token, target, source)) return;
    _currentState = _currentState.copyWith(
      surveyImageBytes: bytes,
      surveyImage: image,
      plateScale: FramingPlateScale(
        surveyFovWidthDeg: requestWidth,
        surveyFovHeightDeg: requestHeight,
        imagePixelWidth: image.width,
        imagePixelHeight: image.height,
      ),
      isLoadingImage: false,
    );
  }

  /// Attempt to serve a pinned survey snapshot from the on-disk cache.
  ///
  /// Returns `true` (and updates _currentState with the decoded image + plate scale)
  /// only when both the cached image file and its FOV companion sidecar exist.
  /// A miss — including the case where the sidecar is absent and the recorded
  /// FOV cannot be recovered — returns `false` so the caller falls through to
  /// the network. Any IO/decode error is surfaced via [developer.log] and also
  /// returns `false` rather than masking a real fetch failure.
  Future<bool> _tryServeFromCache({
    required Object token,
    required FramingTarget target,
    required double raHours,
    required double decDegrees,
    required SurveySource source,
  }) async {
    try {
      // Probe the cache through the single offline-first read API so the
      // notifier, the family provider's consumers, and any test override all
      // share one read path (and one overridable cache-dir configuration).
      // `refresh` (not `read`) forces a fresh disk probe so a snapshot pinned
      // since the last load is seen rather than a memoized miss.
      final file = await _ref.refresh(
        cachedSurveyImageFileProvider((
          raHours: raHours,
          decDegrees: decDegrees,
          source: source,
        )).future,
      );
      if (file == null) return false;

      final fov = await _readRequestFov(
        raHours: raHours,
        decDegrees: decDegrees,
        source: source,
      );
      if (fov == null) {
        // Image is cached but the meta sidecar carries no stored FOV: rebuilding
        // the registration linkage would be guesswork, so treat as a miss and
        // refetch (which will then record the FOV into the sidecar).
        return false;
      }

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return false;

      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(bytes, completer.complete);
      final image = await completer.future;

      if (!_isCurrentSurveyRequest(token, target, source)) return true;
      _currentState = _currentState.copyWith(
        surveyImageBytes: bytes,
        surveyImage: image,
        plateScale: FramingPlateScale(
          surveyFovWidthDeg: fov.$1,
          surveyFovHeightDeg: fov.$2,
          imagePixelWidth: image.width,
          imagePixelHeight: image.height,
        ),
        isLoadingImage: false,
      );
      return true;
    } catch (e, stack) {
      developer.log(
        'FramingProvider: offline cache read failed; falling back to network: $e',
        name: 'FramingProvider',
        level: 900,
        error: e,
        stackTrace: stack,
      );
      return false;
    }
  }

  /// Absolute path of the cache metadata sidecar for a survey snapshot.
  ///
  /// This mirrors the framing cache service's own convention
  /// (`<imagePath>.meta.json`) so the FOV is stored *inside the meta already
  /// written* by [FramingImageCacheService.saveSurveyImage] rather than in a
  /// separate file. Reusing the same sidecar means `listCachedImages` (which
  /// already filters `.meta.json`) does not surface a phantom cache entry.
  Future<String> _metaSidecarPath({
    required double raHours,
    required double decDegrees,
    required SurveySource source,
  }) async {
    final cache = _ref.read(framingImageCacheServiceProvider);
    final imagePath = await cache.resolvePath(
      raHours: raHours,
      decDegrees: decDegrees,
      source: source,
    );
    return '$imagePath.meta.json';
  }

  /// Record the requested FOV into the cache metadata sidecar so a later offline
  /// load can rebuild the plate scale.
  ///
  /// Read-modify-write: it only augments a sidecar the cache service already
  /// wrote (i.e. an image the user pinned). When no sidecar exists there is no
  /// pinned image to register against, so there is nothing to record and the
  /// method is a no-op. Best-effort: a write failure is logged but never fails
  /// the network load — the in-memory image is good.
  Future<void> _recordRequestFov({
    required double raHours,
    required double decDegrees,
    required SurveySource source,
    required double fovWidthDeg,
    required double fovHeightDeg,
  }) async {
    try {
      final path = await _metaSidecarPath(
        raHours: raHours,
        decDegrees: decDegrees,
        source: source,
      );
      final file = File(path);
      if (!await file.exists()) {
        // No pinned snapshot to register against; nothing to record.
        return;
      }
      final decoded = jsonDecode(await file.readAsString());
      final meta = decoded is Map
          ? Map<String, Object?>.from(decoded)
          : <String, Object?>{};
      meta['fovWidthDeg'] = fovWidthDeg;
      meta['fovHeightDeg'] = fovHeightDeg;
      await file.writeAsString(jsonEncode(meta), flush: true);
    } catch (e, stack) {
      developer.log(
        'FramingProvider: failed to record request FOV in cache metadata: $e',
        name: 'FramingProvider',
        level: 900,
        error: e,
        stackTrace: stack,
      );
    }
  }

  /// Read back the requested FOV recorded by [_recordRequestFov] from the cache
  /// metadata sidecar, or `null` when no sidecar exists or it lacks a valid FOV.
  Future<(double, double)?> _readRequestFov({
    required double raHours,
    required double decDegrees,
    required SurveySource source,
  }) async {
    final path = await _metaSidecarPath(
      raHours: raHours,
      decDegrees: decDegrees,
      source: source,
    );
    final file = File(path);
    if (!await file.exists()) return null;

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    final width = (decoded['fovWidthDeg'] as num?)?.toDouble();
    final height = (decoded['fovHeightDeg'] as num?)?.toDouble();
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return (width, height);
  }

  String _buildAladinUrl(
    double raDeg,
    double decDeg,
    double widthDeg,
    double heightDeg,
    SurveySource source,
    int pixelWidth,
  ) {
    final hipsId = _getHipsId(source);
    final pixelHeight = (pixelWidth * heightDeg / widthDeg).round();
    return 'https://alasky.cds.unistra.fr/hips-image-services/hips2fits'
        '?hips=$hipsId'
        '&ra=$raDeg'
        '&dec=$decDeg'
        '&fov=${widthDeg.toStringAsFixed(4)}'
        '&width=$pixelWidth'
        '&height=$pixelHeight'
        '&format=jpg';
  }

  String _buildSkyViewUrl(
    double raDeg,
    double decDeg,
    double widthDeg,
    double heightDeg,
    SurveySource source,
    int pixelWidth,
  ) {
    final surveyId = _getSkyViewSurvey(source);
    final pixelHeight = (pixelWidth * heightDeg / widthDeg).round();
    return 'https://skyview.gsfc.nasa.gov/current/cgi/runquery.pl'
        '?Position=$raDeg,$decDeg'
        '&Survey=$surveyId'
        '&Pixels=$pixelWidth,$pixelHeight'
        '&Size=${widthDeg.toStringAsFixed(4)},${heightDeg.toStringAsFixed(4)}'
        '&Return=JPEG'
        '&Projection=Tan'
        '&Coordinates=J2000';
  }

  String _getHipsId(SurveySource source) {
    switch (source) {
      case SurveySource.dss2Red:
        return 'CDS/P/DSS2/red';
      case SurveySource.dss2Blue:
        return 'CDS/P/DSS2/blue';
      case SurveySource.dss2IR:
        return 'CDS/P/DSS2/NIR';
      case SurveySource.sdss:
        return 'CDS/P/SDSS9/color';
      case SurveySource.twomassJ:
        return 'CDS/P/2MASS/J';
      case SurveySource.twomassH:
        return 'CDS/P/2MASS/H';
      case SurveySource.twomassK:
        return 'CDS/P/2MASS/K';
      case SurveySource.wise12:
        return 'CDS/P/WISE/W3';
    }
  }

  String _getSkyViewSurvey(SurveySource source) {
    switch (source) {
      case SurveySource.dss2Red:
        return 'DSS2R';
      case SurveySource.dss2Blue:
        return 'DSS2B';
      case SurveySource.dss2IR:
        return 'DSS2IR';
      case SurveySource.sdss:
        return 'SDSSg';
      case SurveySource.twomassJ:
        return '2MASSJ';
      case SurveySource.twomassH:
        return '2MASSH';
      case SurveySource.twomassK:
        return '2MASSK';
      case SurveySource.wise12:
        return 'WISE 12';
    }
  }

  Future<(double, double)?> _getCurrentFOV() async {
    if (_currentState.useCustomEquipment &&
        _currentState.customEquipment != null) {
      return (
        _currentState.customEquipment!.fovWidthDeg,
        _currentState.customEquipment!.fovHeightDeg,
      );
    }

    // Delegate profile FOV math to the canonical OpticalConfig.fieldOfView,
    // which derives sensor dimensions from the active profile + connected
    // camera capabilities. This replaces the hand-rolled Taylor-series atan
    // approximation and keeps a single source of truth for FOV across the app.
    try {
      final optical = _ref.read(opticalConfigProvider);
      if (optical == null) {
        return null;
      }
      final fov = optical.fieldOfView;
      if (fov == null) {
        developer.log(
          'Cannot compute profile FOV: optical config lacks focal length or '
          'camera sensor specs (focalLength=${optical.focalLength}, '
          'sensorWidth=${optical.sensorWidth}, sensorHeight=${optical.sensorHeight}, '
          'pixelSize=${optical.pixelSize}).',
          name: 'Framing',
          level: 900,
        );
        return null;
      }
      return fov;
    } catch (error, stack) {
      developer.log(
        'Failed to compute framing FOV from active profile.',
        name: 'Framing',
        level: 1000,
        error: error,
        stackTrace: stack,
      );
    }

    return null;
  }
}
