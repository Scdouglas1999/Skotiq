part of 'annotation_service.dart';

// SNR monitoring and progressive annotation reveal

extension AnnotationSnrTracker on AnnotationService {
  /// Calculate magnitude limit based on current SNR
  /// Formula: magnitudeLimit = baseMagnitude + log2(currentSNR / baseSNR) * 1.5
  double calculateSnrBasedMagnitudeLimit(double snr) {
    if (snr <= _SnrAnnotationConstants.baseSnr) {
      return _SnrAnnotationConstants.baseMagnitude;
    }

    final snrRatio = snr / _SnrAnnotationConstants.baseSnr;
    final magnitudeBoost = (math.log(snrRatio) / math.ln2) * 1.5;
    final limit = _SnrAnnotationConstants.baseMagnitude + magnitudeBoost;

    return limit.clamp(
      _SnrAnnotationConstants.baseMagnitude,
      _SnrAnnotationConstants.maxMagnitude,
    );
  }

  /// Check if SNR has changed enough to warrant re-annotation.
  ///
  /// Handles both improvements (reveal more objects) and regressions
  /// (reduce magnitude limit when SNR drops >30% from peak).
  void checkSnrForReAnnotation(double currentSnr) {
    // Skip if we're already processing
    final state = _ref.read(annotationStateProvider);
    if (state.isProcessing) return;

    // Skip if SNR is too low
    if (currentSnr < _SnrAnnotationConstants.minimumSnrThreshold) return;

    // Skip if we don't have a previous annotation to build upon
    final currentAnnotation = _ref.read(currentAnnotationProvider);
    if (currentAnnotation == null || _lastPlateSolve == null) return;

    // Check if enough time has passed since last annotation
    if (_lastAnnotationTime != null) {
      final elapsed = DateTime.now().difference(_lastAnnotationTime!);
      if (elapsed < _SnrAnnotationConstants.reAnnotationDebounce) return;
    }

    // Update peak SNR tracking
    if (_peakAnnotationSnr == null || currentSnr > _peakAnnotationSnr!) {
      _peakAnnotationSnr = currentSnr;
    }

    // Calculate new magnitude limit
    final newMagnitudeLimit = calculateSnrBasedMagnitudeLimit(currentSnr);

    // Check for SNR regression: if current SNR dropped >30% from peak,
    // reduce the magnitude limit proportionally and re-annotate.
    if (_peakAnnotationSnr != null && _lastAnnotationSnr != null) {
      final dropRatio = currentSnr / _peakAnnotationSnr!;
      if (dropRatio < 0.7) {
        // SNR dropped more than 30% from peak — reduce magnitude limit
        if (newMagnitudeLimit < _currentSnrMagnitudeLimit - 0.5) {
          _logger.info(
            'SNR regressed from peak ${_peakAnnotationSnr!.toStringAsFixed(1)} to ${currentSnr.toStringAsFixed(1)} '
            '(${((1.0 - dropRatio) * 100).toStringAsFixed(0)}% drop), '
            'reducing magnitude limit from ${_currentSnrMagnitudeLimit.toStringAsFixed(1)} to ${newMagnitudeLimit.toStringAsFixed(1)}',
            source: 'Annotation',
          );

          progressiveReAnnotateWithReducedLimit(currentSnr, newMagnitudeLimit);
          return;
        }
      }
    }

    // Check if SNR improved significantly
    if (_lastAnnotationSnr != null) {
      final snrRatio = currentSnr / _lastAnnotationSnr!;
      if (snrRatio < _SnrAnnotationConstants.snrImprovementThreshold) return;

      // Also check if the new magnitude limit is actually higher
      if (newMagnitudeLimit <= _currentSnrMagnitudeLimit + 0.5) return;
    }

    // Calculate improvement percentage for the suggestion banner
    final improvementPercent =
        _lastAnnotationSnr != null && _lastAnnotationSnr! > 0
        ? ((currentSnr - _lastAnnotationSnr!) / _lastAnnotationSnr!) * 100.0
        : 0.0;

    // If SNR improved >=40%, surface a prominent re-annotate suggestion
    if (improvementPercent >= 40.0) {
      _ref
          .read(reAnnotateSuggestionProvider.notifier)
          .state = ReAnnotateSuggestion(
        shouldShow: true,
        improvementPercent: improvementPercent,
      );
    }

    // Trigger progressive re-annotation (increasing)
    _logger.info(
      'SNR improved from ${_lastAnnotationSnr?.toStringAsFixed(1) ?? "N/A"} to ${currentSnr.toStringAsFixed(1)}, '
      'updating magnitude limit from ${_currentSnrMagnitudeLimit.toStringAsFixed(1)} to ${newMagnitudeLimit.toStringAsFixed(1)}',
      source: 'Annotation',
    );

    progressiveReAnnotate(currentSnr, newMagnitudeLimit);
  }

  /// Re-annotate with a higher magnitude limit, keeping existing objects
  Future<void> progressiveReAnnotate(
    double currentSnr,
    double newMagnitudeLimit,
  ) async {
    final currentAnnotation = _ref.read(currentAnnotationProvider);
    final plateSolve = _lastPlateSolve;
    if (currentAnnotation == null || plateSolve == null) return;
    final generation = _annotationRunGeneration;
    final backend = _ref.read(backendProvider);
    bool isCurrent() =>
        _isCurrentAnnotationRun(generation, backend) &&
        identical(_lastPlateSolve, plateSolve);

    try {
      if (!isCurrent()) return;
      _ref.read(annotationStateProvider.notifier).state =
          const AnnotationState.searching();

      final settings = _ref.read(annotationSettingsProvider).valueOrNull;
      final includeStars =
          settings?.visibleTypes.contains(AnnotationObjectFilter.stars) ??
          false;

      // Search for additional objects with the new, higher magnitude limit
      final additionalObjects = await findObjectsInFov(
        plateSolve: plateSolve,
        includeStars: includeStars,
        minMagnitude: newMagnitudeLimit,
        snrBasedMagnitudeCutoff: newMagnitudeLimit,
      );
      if (!isCurrent()) return;

      // Filter to only new objects (not already revealed)
      final newObjects = additionalObjects
          .where((obj) => !_revealedObjectIds.contains(obj.id))
          .toList();

      if (newObjects.isEmpty) {
        _logger.debug(
          'No new objects found at magnitude ${newMagnitudeLimit.toStringAsFixed(1)}',
          source: 'Annotation',
        );
        _ref.read(annotationStateProvider.notifier).state =
            AnnotationState.complete(currentAnnotation.objects.length);
        return;
      }

      // Add new object IDs to revealed set
      for (final obj in newObjects) {
        _revealedObjectIds.add(obj.id);
      }

      _logger.info(
        'Found ${newObjects.length} new objects (total: ${_revealedObjectIds.length})',
        source: 'Annotation',
      );

      // Merge new objects with existing annotation
      final mergedObjects = [...currentAnnotation.objects, ...newObjects];

      final updatedAnnotation = currentAnnotation.copyWith(
        objects: mergedObjects,
        timestamp: DateTime.now(),
      );

      // Update state
      _lastAnnotationSnr = currentSnr;
      _lastAnnotationTime = DateTime.now();
      _currentSnrMagnitudeLimit = newMagnitudeLimit;

      _ref.read(currentAnnotationProvider.notifier).state = updatedAnnotation;
      _ref.read(annotationStateProvider.notifier).state =
          AnnotationState.complete(updatedAnnotation.objects.length);
    } catch (e) {
      if (!isCurrent()) return;
      _logger.error(
        'Error during progressive re-annotation: $e',
        source: 'Annotation',
      );
      _ref.read(annotationStateProvider.notifier).state = AnnotationState.error(
        e.toString(),
      );
    }
  }

  /// Re-annotate with a reduced magnitude limit due to SNR regression.
  ///
  /// Unlike progressive re-annotation (which adds objects), this filters
  /// existing objects down to those within the new, lower magnitude limit,
  /// then re-queries catalogs at the reduced limit.
  Future<void> progressiveReAnnotateWithReducedLimit(
    double currentSnr,
    double newMagnitudeLimit,
  ) async {
    final currentAnnotation = _ref.read(currentAnnotationProvider);
    final plateSolve = _lastPlateSolve;
    if (currentAnnotation == null || plateSolve == null) return;
    final generation = _annotationRunGeneration;
    final backend = _ref.read(backendProvider);
    bool isCurrent() =>
        _isCurrentAnnotationRun(generation, backend) &&
        identical(_lastPlateSolve, plateSolve);

    try {
      if (!isCurrent()) return;
      _ref.read(annotationStateProvider.notifier).state =
          const AnnotationState.searching();

      // Filter existing objects to only those within the new magnitude limit
      final filteredObjects = currentAnnotation.objects.where((obj) {
        if (obj.magnitude == null) return true;
        return obj.magnitude! <= newMagnitudeLimit;
      }).toList();

      // Rebuild revealed object set
      _revealedObjectIds.clear();
      for (final obj in filteredObjects) {
        _revealedObjectIds.add(obj.id);
      }

      _logger.info(
        'SNR regression: reduced from ${currentAnnotation.objects.length} to '
        '${filteredObjects.length} objects at magnitude limit ${newMagnitudeLimit.toStringAsFixed(1)}',
        source: 'Annotation',
      );

      final updatedAnnotation = currentAnnotation.copyWith(
        objects: filteredObjects,
        timestamp: DateTime.now(),
      );

      // Update state
      _lastAnnotationSnr = currentSnr;
      _lastAnnotationTime = DateTime.now();
      _currentSnrMagnitudeLimit = newMagnitudeLimit;

      _ref.read(currentAnnotationProvider.notifier).state = updatedAnnotation;
      _ref.read(annotationStateProvider.notifier).state =
          AnnotationState.complete(updatedAnnotation.objects.length);
    } catch (e) {
      if (!isCurrent()) return;
      _logger.error(
        'Error during reduced-limit re-annotation: $e',
        source: 'Annotation',
      );
      _ref.read(annotationStateProvider.notifier).state = AnnotationState.error(
        e.toString(),
      );
    }
  }
}
