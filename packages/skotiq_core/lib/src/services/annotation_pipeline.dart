part of 'annotation_service.dart';

// Annotation pipeline: plate solve -> catalog search -> merge logic

/// Thrown when a catalog/DB query inside the annotation pipeline genuinely
/// fails (the query threw, the underlying file/DB read errored, etc.).
///
/// A broken query (corrupt catalog file, I/O error, malformed row) must stay
/// distinguishable from a legitimate "0 objects in this frame" result, which
/// otherwise reach the user as the same "0 objects found".
///
/// A query that succeeds but matches nothing is NOT a failure and must NOT
/// throw this; it simply contributes no objects. This exception is reserved
/// for real failures so they propagate to [AnnotationPipeline.processNewImage],
/// which surfaces them as [AnnotationState.error] (a status the UI renders with
/// an error icon + actionable hint) instead of a silent empty success.
class AnnotationCatalogQueryException implements Exception {
  /// Which catalog was being queried, e.g. `'annotation'`, `'DSO'`, `'star'`.
  /// Used to compose log lines and the user-visible error message.
  final String catalog;

  /// The original error that the catalog query threw.
  final Object cause;

  const AnnotationCatalogQueryException(this.catalog, this.cause);

  @override
  String toString() => 'Failed to query the $catalog catalog: $cause';
}

extension AnnotationPipeline on AnnotationService {
  /// Process a new image through the full annotation pipeline:
  /// plate solve -> catalog search -> object merge -> state update.
  Future<void> processNewImage(CapturedImageData image) async {
    final generation = ++_annotationRunGeneration;
    final backend = _ref.read(backendProvider);
    bool isCurrent() => _isCurrentAnnotationRun(generation, backend);

    if (image.settings.frameType != FrameType.light &&
        image.settings.frameType != FrameType.snapshot) {
      _ref.read(currentAnnotationProvider.notifier).state = null;
      _ref.read(annotationStateProvider.notifier).state =
          const AnnotationState.idle();
      return;
    }

    if (image.filePath == null) {
      _logger.debug('Skipping annotation - no file path', source: 'Annotation');
      return;
    }

    // Check if auto-annotate is enabled
    final AnnotationSettings settings;
    try {
      settings = await _ref.read(annotationSettingsProvider.future);
    } catch (error, stackTrace) {
      if (!isCurrent()) return;
      _logger.error(
        'Cannot start annotation because settings are unavailable: '
        '$error\nStack trace: $stackTrace',
        source: 'Annotation',
      );
      _ref.read(annotationStateProvider.notifier).state = AnnotationState.error(
        'Annotation settings are unavailable: $error',
      );
      return;
    }
    if (!isCurrent()) return;
    if (!settings.autoAnnotate) {
      _logger.debug('Auto-annotate disabled, skipping', source: 'Annotation');
      _ref.read(annotationStateProvider.notifier).state =
          const AnnotationState.idle();
      return;
    }

    // Check if annotations are enabled at all
    if (!settings.enabled) {
      _logger.debug('Annotations disabled, skipping', source: 'Annotation');
      _ref.read(annotationStateProvider.notifier).state =
          const AnnotationState.idle();
      return;
    }

    _logger.info('New image detected: ${image.filePath}', source: 'Annotation');

    try {
      // PRE-FLIGHT CHECK 1: Verify CatalogManager is initialized
      _ref.read(annotationStateProvider.notifier).state =
          const AnnotationState.checking();

      if (!_catalogManager.isInitialized) {
        _logger.warning(
          'CatalogManager not initialized - catalogs not available',
          source: 'Annotation',
        );
        // CatalogManager should be initialized by the app on startup
        // If not initialized here, it means catalogs haven't been set up
        _ref.read(annotationStateProvider.notifier).state =
            const AnnotationState.catalogsNotInstalled();
        return;
      }

      // PRE-FLIGHT CHECK 2: Verify at least one catalog is installed
      final dsoStatus = await _catalogManager.getDsoCatalogStatus();
      if (!isCurrent()) return;
      final starStatus = await _catalogManager.getStarCatalogStatus();
      if (!isCurrent()) return;
      final annotationStatus = await _catalogManager
          .getAnnotationCatalogStatus();
      if (!isCurrent()) return;

      final hasDsoCatalog = dsoStatus.isInstalled;
      final hasStarCatalog = starStatus.isInstalled;
      final hasAnnotationCatalog = annotationStatus.isInstalled;

      if (!hasDsoCatalog && !hasStarCatalog && !hasAnnotationCatalog) {
        _logger.warning(
          'No catalogs installed - DSO: $hasDsoCatalog, Stars: $hasStarCatalog, Annotation: $hasAnnotationCatalog',
          source: 'Annotation',
        );
        _ref.read(annotationStateProvider.notifier).state =
            const AnnotationState.catalogsNotInstalled();
        return;
      }

      _logger.info(
        'Catalogs available - DSO: $hasDsoCatalog, Stars: $hasStarCatalog, Annotation: $hasAnnotationCatalog',
        source: 'Annotation',
      );

      // PRE-FLIGHT CHECK 3: Verify backend is available
      if (backend is DisconnectedBackend) {
        _logger.error(
          'Backend disconnected, cannot plate solve',
          source: 'Annotation',
        );
        _ref.read(annotationStateProvider.notifier).state =
            const AnnotationState.error('Backend not connected');
        return;
      }

      // STEP 1: Plate Solve
      _ref.read(annotationStateProvider.notifier).state =
          const AnnotationState.plateSolving();
      _logger.info(
        'Starting plate solve for: ${image.filePath}',
        source: 'Annotation',
      );

      // Try to get mount position hints for faster solving
      double? hintRaHours;
      double? hintDec;
      try {
        final mountState = _ref.read(mountStateProvider);
        if (mountState.ra != null && mountState.dec != null) {
          // `mountState.ra` is HOURS (ASCOM RightAscension), which is also the
          // unit PlateSolveService takes; it converts to the solver's degrees
          // itself (`_raHoursToSolverDegrees` is the same identity, kept for
          // the callers that still hand the backend degrees directly).
          hintRaHours = mountState.ra;
          hintDec = mountState.dec;
          _logger.debug(
            'Using mount position hints: RA=${_raHoursToSolverDegrees(mountState.ra!)}'
            '°, Dec=$hintDec°',
            source: 'Annotation',
          );
        }
      } catch (e) {
        // Mount state not available, continue without hints
        _logger.debug(
          'Mount position hints not available',
          source: 'Annotation',
        );
      }

      // Solve through the shared service, not `backend.plateSolve` directly.
      // The direct call was the only solve path in the app that skipped the
      // service, and it therefore skipped everything the service does: the
      // operator's configured search radius, the solver-choice validation, the
      // ASTAP→astrometry fallback, the single-flight gate (two annotate solves
      // could run ASTAP on the same frame concurrently), and — the reason a
      // failed annotate solve left no trace anywhere — the one log line that
      // records a solve's outcome.
      final PlateSolveResult? result;
      try {
        result = await _ref
            .read(plateSolveServiceProvider)
            .solveForAnnotation(
              isCurrent: isCurrent,
              imagePath: image.filePath!,
              hintRaHours: hintRaHours,
              hintDecDegrees: hintDec,
            );
      } on SolverNotAvailableError catch (e) {
        if (!isCurrent()) return;
        _logger.warning('Cannot annotate: ${e.message}', source: 'Annotation');
        _ref.read(annotationStateProvider.notifier).state =
            AnnotationState.plateSolveFailed(e.message);
        return;
      }
      if (!isCurrent() || result == null) return;

      if (!result.success) {
        final detailedReason = _describePlateSolveFailure(result.error);
        _logger.warning(
          'Plate solve failed: $detailedReason (raw: ${result.error})',
          source: 'Annotation',
        );
        _ref.read(annotationStateProvider.notifier).state =
            AnnotationState.plateSolveFailed(detailedReason);
        return;
      }

      // A success flag is not a solution. Every downstream step maps catalog
      // coordinates onto pixels through the centre and the scale, so a result
      // carrying neither searches a field of zero size and comes back with
      // nothing — which the chip then reported as the benign "Found 0 objects",
      // a statement about the sky rather than about a solve that did not
      // produce a solution.
      final geometryProblem = _unusableSolveGeometry(result);
      if (geometryProblem != null) {
        _logger.warning(
          'Plate solve reported success without a usable solution: '
          '$geometryProblem (RA=${result.ra}, Dec=${result.dec}, '
          'scale=${result.pixelScale}, field=${result.fieldWidth})',
          source: 'Annotation',
        );
        _ref.read(annotationStateProvider.notifier).state =
            AnnotationState.plateSolveFailed(geometryProblem);
        return;
      }

      _logger.info(
        'Plate solve success: RA=${result.ra.toStringAsFixed(4)}, '
        'Dec=${result.dec.toStringAsFixed(4)}, '
        'Scale=${result.pixelScale.toStringAsFixed(2)}"/px, '
        'Rotation=${result.rotation.toStringAsFixed(1)} deg',
        source: 'Annotation',
      );

      // STEP 2: Create PlateSolveData
      //
      // The catalog search radius is derived from the field size, so a solver
      // that reports a centre and a scale but leaves the field at zero (the
      // local ASTAP/astrometry fallback parsers do exactly that — they recover
      // position and scale only) searched a cone of radius ZERO and came back
      // empty. That is how a solved frame reported "Found 0 objects": not a
      // statement about the sky, an artefact of a missing number we can
      // compute ourselves from the scale and the frame's own dimensions.
      final fieldSize = _fieldSizeDegrees(result, image);
      if (fieldSize == null) {
        _logger.warning(
          'Plate solve reported success without a usable field size: '
          'scale=${result.pixelScale}, field=${result.fieldWidth}x'
          '${result.fieldHeight}, image=${image.width}x${image.height}',
          source: 'Annotation',
        );
        _ref
            .read(annotationStateProvider.notifier)
            .state = const AnnotationState.plateSolveFailed(
          'Solver returned no field size and none could be derived from '
          'the frame — nothing can be matched against a field of zero '
          'size',
        );
        return;
      }

      final plateSolveData = plateSolveDataFromResult(
        result,
        imageWidth: image.width,
        imageHeight: image.height,
        fieldWidth: fieldSize.width,
        fieldHeight: fieldSize.height,
      );

      // Store plate solve for progressive re-annotation
      _lastPlateSolve = plateSolveData;

      // STEP 3: Calculate initial SNR-based magnitude limit
      final currentSnr = image.stats.snr;
      double initialMagnitudeLimit;

      if (currentSnr != null &&
          currentSnr >= _SnrAnnotationConstants.minimumSnrThreshold) {
        initialMagnitudeLimit = calculateSnrBasedMagnitudeLimit(currentSnr);
        _lastAnnotationSnr = currentSnr;
        _peakAnnotationSnr = currentSnr;
        _logger.debug(
          'Initial SNR: ${currentSnr.toStringAsFixed(2)}, magnitude limit: ${initialMagnitudeLimit.toStringAsFixed(1)}',
          source: 'Annotation',
        );
      } else {
        // If no SNR available or too low, use conservative base magnitude
        initialMagnitudeLimit = _SnrAnnotationConstants.baseMagnitude;
        _logger.debug(
          'SNR not available or too low, using base magnitude limit: ${initialMagnitudeLimit.toStringAsFixed(1)}',
          source: 'Annotation',
        );
      }

      _currentSnrMagnitudeLimit = initialMagnitudeLimit;
      _lastAnnotationTime = DateTime.now();

      // STEP 4: Search Catalogs
      _ref.read(annotationStateProvider.notifier).state =
          const AnnotationState.searching();

      // Get annotation settings for filtering
      final includeStars = settings.visibleTypes.contains(
        AnnotationObjectFilter.stars,
      );
      final userMagnitudeCutoff = settings.magnitudeCutoff;

      // Use the minimum of SNR-based limit and user setting for initial search
      final effectiveMagnitudeLimit = math.min(
        initialMagnitudeLimit,
        userMagnitudeCutoff,
      );

      _logger.debug(
        'Searching catalogs with magnitude cutoff: ${effectiveMagnitudeLimit.toStringAsFixed(1)} '
        '(SNR-based: ${initialMagnitudeLimit.toStringAsFixed(1)}, user: ${userMagnitudeCutoff.toStringAsFixed(1)}), '
        'include stars: $includeStars',
        source: 'Annotation',
      );

      final annotation = await annotateImage(
        imagePath: image.filePath!,
        plateSolve: plateSolveData,
        includeStars: includeStars && hasStarCatalog,
        minMagnitude: effectiveMagnitudeLimit,
        snrBasedMagnitudeCutoff: effectiveMagnitudeLimit,
        onPartialResult: (partial) {
          if (!isCurrent()) return;
          _ref.read(currentAnnotationProvider.notifier).state = partial;
          _ref.read(annotationStateProvider.notifier).state = AnnotationState(
            status: AnnotationStatus.searchingCatalogs,
            message:
                'Found ${partial.objects.length} ${partial.objects.length == 1 ? 'object' : 'objects'} · searching deep catalog…',
            objectsFound: partial.objects.length,
          );
        },
      );
      if (!isCurrent()) return;

      // Track revealed object IDs for progressive updates
      for (final obj in annotation.objects) {
        _revealedObjectIds.add(obj.id);
      }

      // STEP 5: Update providers with result
      _ref.read(currentAnnotationProvider.notifier).state = annotation;
      _ref.read(annotationStateProvider.notifier).state =
          AnnotationState.complete(annotation.objects.length);

      _logger.info(
        'Annotation complete: ${annotation.objects.length} objects found',
        source: 'Annotation',
      );
    } catch (e, stackTrace) {
      if (!isCurrent()) return;
      _logger.error(
        'Error processing image: $e\nStack trace: $stackTrace',
        source: 'Annotation',
      );
      _ref.read(annotationStateProvider.notifier).state = AnnotationState.error(
        e.toString(),
      );
    }
  }

  /// The field this frame covers, in degrees, or null when it cannot be known.
  ///
  /// Prefers whatever the solver reported. When the solver left it at zero (or
  /// negative / non-finite), it is reconstructed from the solved plate scale
  /// and the frame's pixel dimensions — `arcsec/px × px ÷ 3600` — which is the
  /// same identity the solver would have used. Returns null only when neither
  /// source exists, because a zero-size field silently turns every catalog
  /// query into a query about nothing.
  ({double width, double height})? _fieldSizeDegrees(
    PlateSolveResult result,
    CapturedImageData image,
  ) {
    bool usable(double value) => value.isFinite && value > 0;

    if (usable(result.fieldWidth) && usable(result.fieldHeight)) {
      return (width: result.fieldWidth, height: result.fieldHeight);
    }
    if (!usable(result.pixelScale) || image.width <= 0 || image.height <= 0) {
      return null;
    }
    return (
      width: result.pixelScale * image.width / 3600.0,
      height: result.pixelScale * image.height / 3600.0,
    );
  }

  /// Generate annotations for an image given its plate solve result
  ///
  /// [snrBasedMagnitudeCutoff] - Optional magnitude cutoff based on current SNR.
  /// If provided, this is used for progressive annotation reveal.
  Future<ImageAnnotation> annotateImage({
    required String imagePath,
    required PlateSolveData plateSolve,
    bool includeStars = true,
    double minMagnitude = 15.0,
    double minSize = 0.5,
    double? snrBasedMagnitudeCutoff,
    void Function(ImageAnnotation)? onPartialResult,
  }) async {
    _logger.info('Starting annotation for $imagePath', source: 'Annotation');

    final objects = await findObjectsInFov(
      plateSolve: plateSolve,
      includeStars: includeStars,
      minMagnitude: minMagnitude,
      minSize: minSize,
      snrBasedMagnitudeCutoff: snrBasedMagnitudeCutoff,
      onPartialResult: onPartialResult == null
          ? null
          : (objects) => onPartialResult(
              ImageAnnotation(
                imagePath: imagePath,
                timestamp: DateTime.now(),
                plateSolve: plateSolve,
                objects: objects,
              ),
            ),
    );

    _logger.info(
      'Found ${objects.length} objects in FOV',
      source: 'Annotation',
    );

    return ImageAnnotation(
      imagePath: imagePath,
      timestamp: DateTime.now(),
      plateSolve: plateSolve,
      objects: objects,
    );
  }

  /// Find all catalog objects within the field of view
  ///
  /// [snrBasedMagnitudeCutoff] - Optional magnitude cutoff based on current SNR.
  /// If provided, this takes precedence over [minMagnitude] for filtering objects.
  Future<List<CelestialObjectAnnotation>> findObjectsInFov({
    required PlateSolveData plateSolve,
    bool includeStars = false,
    double minMagnitude = 15.0,
    double minSize = 0.5,
    double? snrBasedMagnitudeCutoff,
    void Function(List<CelestialObjectAnnotation>)? onPartialResult,
  }) async {
    final annotations = <CelestialObjectAnnotation>[];

    // Use SNR-based cutoff if provided, otherwise use minMagnitude
    final effectiveMagnitudeCutoff = snrBasedMagnitudeCutoff ?? minMagnitude;

    // Calculate search radius (diagonal of FOV)
    final fovDiagonal = math.sqrt(
      plateSolve.fieldWidth * plateSolve.fieldWidth +
          plateSolve.fieldHeight * plateSolve.fieldHeight,
    );
    final searchRadius = fovDiagonal / 2 * 1.1; // Add 10% margin

    _logger.debug(
      'Searching DSO catalog within $searchRadius degrees of RA=${plateSolve.ra}, Dec=${plateSolve.dec}, '
      'magnitude cutoff: ${effectiveMagnitudeCutoff.toStringAsFixed(1)}',
      source: 'Annotation',
    );

    // Query BOTH annotation catalog and DSO catalog, then merge results.
    // The annotation catalog (GLADE+/HyperLEDA/OpenNGC merged) has richer
    // data for galaxies, while the standalone DSO catalog may have objects
    // the annotation catalog misses (and vice-versa).

    // Temporary map for deduplication: keyed by normalized name or position.
    final deduplicatedById = <String, CelestialObjectAnnotation>{};

    // Query the small DSO catalog first so bright labels can appear immediately.
    try {
      final dsos = await _catalogManager.searchDsoNearby(
        ra: plateSolve.ra,
        dec: plateSolve.dec,
        radiusDegrees: searchRadius,
        maxMagnitude: effectiveMagnitudeCutoff,
      );

      _logger.debug(
        'Found ${dsos.length} DSOs in search area',
        source: 'Annotation',
      );

      for (final dso in dsos) {
        if (dso.majorAxis != null && dso.majorAxis! < minSize) {
          continue;
        }

        final pixelCoords = plateSolve.skyToPixel(dso.ra, dso.dec);
        if (pixelCoords == null) {
          continue;
        }

        if (pixelCoords.x < 0 ||
            pixelCoords.x >= plateSolve.imageWidth ||
            pixelCoords.y < 0 ||
            pixelCoords.y >= plateSolve.imageHeight) {
          continue;
        }

        final objectType = _mapAnnotationObjectType(
          AnnotationObject.fromOpenNgc(dso).type,
        );

        final annotation = CelestialObjectAnnotation(
          id: 'dso_${dso.name}',
          name: dso.displayName,
          type: objectType,
          ra: dso.ra,
          dec: dso.dec,
          x: pixelCoords.x,
          y: pixelCoords.y,
          catalogId: dso.name,
          magnitude: dso.magnitude,
          size: dso.majorAxis,
        );

        final dedupeKey = _deduplicationKey(annotation);
        if (!deduplicatedById.containsKey(dedupeKey)) {
          // Keep one entry for duplicate catalog identifiers.
          deduplicatedById[dedupeKey] = annotation;
        } else {
          // Merge: keep the entry with more fields populated
          final existing = deduplicatedById[dedupeKey]!;
          deduplicatedById[dedupeKey] = _mergeAnnotationObjects(
            existing,
            annotation,
          );
        }
      }
    } catch (e, stackTrace) {
      // Genuine failure — surface it. A DSO catalog that simply isn't installed
      // returns an empty list (handled inside searchDsoNearby), so reaching
      // this catch means the query itself broke.
      _logger.error(
        'Error querying DSO catalog: $e\nStack trace: $stackTrace',
        source: 'Annotation',
      );
      throw AnnotationCatalogQueryException('DSO', e);
    }

    // Optionally include bright stars
    if (includeStars) {
      try {
        // For stars, apply the SNR-based cutoff more aggressively
        final starMagnitudeCutoff = effectiveMagnitudeCutoff.clamp(0.0, 10.0);
        final stars = await _catalogManager.searchStarsNearby(
          ra: plateSolve.ra,
          dec: plateSolve.dec,
          radiusDegrees: searchRadius,
          maxMagnitude: starMagnitudeCutoff,
        );

        _logger.debug(
          'Found ${stars.length} stars in search area',
          source: 'Annotation',
        );

        for (final star in stars.take(100)) {
          final pixelCoords = plateSolve.skyToPixel(star.ra, star.dec);
          if (pixelCoords == null) continue;

          // Check if pixel coordinates are within image bounds
          if (pixelCoords.x < 0 ||
              pixelCoords.x >= plateSolve.imageWidth ||
              pixelCoords.y < 0 ||
              pixelCoords.y >= plateSolve.imageHeight) {
            continue;
          }

          annotations.add(
            CelestialObjectAnnotation(
              id: 'star_${star.id}',
              name: star.properName ?? star.catalogId,
              type: ObjectType.star,
              ra: star.ra,
              dec: star.dec,
              x: pixelCoords.x,
              y: pixelCoords.y,
              catalogId: star.catalogId,
              magnitude: star.magnitude,
            ),
          );
        }
      } catch (e, stackTrace) {
        // Genuine failure — surface it rather than dropping stars silently.
        _logger.error(
          'Error querying star catalog: $e\nStack trace: $stackTrace',
          source: 'Annotation',
        );
        throw AnnotationCatalogQueryException('star', e);
      }
    }

    if (deduplicatedById.isNotEmpty || annotations.isNotEmpty) {
      onPartialResult?.call([...deduplicatedById.values, ...annotations]);
    }

    // Enrich the initial labels with the much larger galaxy catalog.
    final annotationCatalog = await _loadAnnotationCatalog();
    if (annotationCatalog != null && annotationCatalog.isAvailable) {
      try {
        final watch = Stopwatch()..start();
        _logger.info('Searching deep annotation catalog', source: 'Annotation');
        final objects = await annotationCatalog.searchNearby(
          ra: plateSolve.ra,
          dec: plateSolve.dec,
          radiusDegrees: searchRadius,
          maxMagnitude: effectiveMagnitudeCutoff,
        );

        _logger.debug(
          'Found ${objects.length} annotation objects in ${watch.elapsedMilliseconds} ms',
          source: 'Annotation',
        );

        for (final obj in objects) {
          if (obj.majorAxis != null && obj.majorAxis! < minSize) {
            continue;
          }

          final pixelCoords = plateSolve.skyToPixel(obj.ra, obj.dec);
          if (pixelCoords == null) {
            continue;
          }

          if (pixelCoords.x < 0 ||
              pixelCoords.x >= plateSolve.imageWidth ||
              pixelCoords.y < 0 ||
              pixelCoords.y >= plateSolve.imageHeight) {
            continue;
          }

          final altName = obj.alternateNames.isNotEmpty
              ? obj.alternateNames.first
              : null;

          final annotation = CelestialObjectAnnotation(
            id: obj.id,
            name: obj.primaryName,
            type: _mapAnnotationObjectType(obj.type),
            ra: obj.ra,
            dec: obj.dec,
            x: pixelCoords.x,
            y: pixelCoords.y,
            catalogId: altName ?? obj.primaryName,
            commonName: altName != null && altName != obj.primaryName
                ? altName
                : null,
            magnitude: obj.magnitude,
            size: obj.majorAxis,
          );

          final dedupeKey = _deduplicationKey(annotation);
          final existing = deduplicatedById[dedupeKey];
          deduplicatedById[dedupeKey] = existing == null
              ? annotation
              : _mergeAnnotationObjects(annotation, existing);
        }
      } catch (e, stackTrace) {
        // Genuine failure (corrupt catalog, I/O error, malformed row) — surface
        // it instead of silently returning a partial list. Re-throwing routes
        // it to processNewImage's error path. (An empty-but-successful query
        // never reaches here.)
        _logger.error(
          'Error querying annotation catalog: $e\nStack trace: $stackTrace',
          source: 'Annotation',
        );
        throw AnnotationCatalogQueryException('annotation', e);
      }
    }

    annotations.insertAll(0, deduplicatedById.values);

    _logger.debug(
      'Total annotations: ${annotations.length}',
      source: 'Annotation',
    );
    return annotations;
  }
}
