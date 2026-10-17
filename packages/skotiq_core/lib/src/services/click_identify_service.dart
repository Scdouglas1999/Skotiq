part of 'annotation_service.dart';

// Click-to-identify query logic

extension ClickIdentifyService on AnnotationService {
  /// Identify an object at specific pixel coordinates
  Future<CelestialObjectAnnotation?> identifyAtPixel({
    required PlateSolveData plateSolve,
    required double x,
    required double y,
    double? searchRadiusArcsec,
  }) async {
    // Convert pixels to RA/Dec
    final coords = plateSolve.pixelToSky(x, y);

    _logger.debug(
      'Identifying object at $x, $y -> RA: ${coords.ra}, Dec: ${coords.dec}',
      source: 'Annotation',
    );

    // Search for object at these coordinates
    final configuredRadius =
        searchRadiusArcsec ??
        (await _ref.read(
          annotationSettingsProvider.future,
        )).clickSearchRadiusArcsec;
    final effectiveRadiusArcsec = configuredRadius.clamp(1.0, 600.0);

    final ObjectData? details;
    try {
      details = await getObjectDetails(
        ra: coords.ra,
        dec: coords.dec,
        radiusArcmin: effectiveRadiusArcsec / 60.0,
      ).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _logger.warning(
        'Click-to-identify timed out after 10s at RA=${coords.ra}, Dec=${coords.dec}',
        source: 'Annotation',
      );
      // Return a sentinel annotation so the UI can distinguish timeout from
      // "nothing found" (null).
      return CelestialObjectAnnotation(
        id: 'timeout_${DateTime.now().millisecondsSinceEpoch}',
        name: 'Query timed out',
        type: ObjectType.unknown,
        ra: coords.ra,
        dec: coords.dec,
        x: x,
        y: y,
        detailedData: ObjectData(
          description:
              'The catalog query timed out after 10 seconds. '
              'Check your network connection and try again.',
          dataSource: 'timeout',
          lastUpdated: DateTime.now(),
        ),
      );
    }

    if (details == null) return null;

    // Convert to annotation format
    final objectType = _inferObjectType(details.objectClass);
    final name =
        details.catalogIds?['Name'] ??
        (details.catalogIds?['NGC'] != null
            ? 'NGC ${details.catalogIds!['NGC']}'
            : null) ??
        (details.catalogIds?['M'] != null
            ? 'M ${details.catalogIds!['M']}'
            : null) ??
        details.simbadId ??
        'Unknown Object';

    return CelestialObjectAnnotation(
      id: 'identified_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      type: objectType,
      ra: coords.ra,
      dec: coords.dec,
      x: x,
      y: y,
      catalogId: details.catalogIds?.entries.firstOrNull?.value,
      detailedData: details,
    );
  }

  /// Get detailed information about an object at given coordinates
  Future<ObjectData?> getObjectDetails({
    required double ra,
    required double dec,
    double radiusArcmin = 1.0,
  }) async {
    ObjectData? result;

    // 1. Check local DSO catalog first (fast)
    final radiusDeg = radiusArcmin / 60.0;
    try {
      final dsos = await _catalogManager.searchDsoNearby(
        ra: ra,
        dec: dec,
        radiusDegrees: radiusDeg,
      );

      if (dsos.isNotEmpty) {
        // Find the closest object
        final closest = dsos.reduce((a, b) {
          final distA = _angularDistance(ra, dec, a.ra, a.dec);
          final distB = _angularDistance(ra, dec, b.ra, b.dec);
          return distA < distB ? a : b;
        });

        result = ObjectData(
          description: closest.typeDescription,
          objectClass: closest.typeDescription,
          catalogIds: {
            'Name': closest.displayName,
            if (closest.messier != null)
              'M': closest.messier!.replaceAll('M', ''),
            if (closest.name.startsWith('NGC'))
              'NGC': closest.name.replaceAll('NGC', '').trim(),
            if (closest.name.startsWith('IC'))
              'IC': closest.name.replaceAll('IC', '').trim(),
          },
          lastUpdated: DateTime.now(),
          dataSource: 'Local Catalog',
        );

        _logger.debug(
          'Found in local DSO catalog: ${closest.displayName}',
          source: 'Annotation',
        );
      }
    } catch (e) {
      _logger.error(
        'Error searching local DSO catalog: $e',
        source: 'Annotation',
      );
    }

    // Also check local star catalog
    if (result == null) {
      try {
        final stars = await _catalogManager.searchStarsNearby(
          ra: ra,
          dec: dec,
          radiusDegrees: radiusDeg,
        );

        if (stars.isNotEmpty) {
          // Find the closest star
          final closest = stars.reduce((a, b) {
            final distA = _angularDistance(ra, dec, a.ra, a.dec);
            final distB = _angularDistance(ra, dec, b.ra, b.dec);
            return distA < distB ? a : b;
          });

          result = ObjectData(
            description: 'Star',
            objectClass: 'Star',
            spectralType: _parseSpectralType(closest.spectralType),
            distance: closest.distance,
            catalogIds: {
              'Name': closest.name,
              if (closest.hipId != null) 'HIP': closest.hipId.toString(),
              if (closest.hdId != null) 'HD': closest.hdId.toString(),
            },
            lastUpdated: DateTime.now(),
            dataSource: 'Local Catalog',
          );

          _logger.debug(
            'Found in local star catalog: ${closest.name}',
            source: 'Annotation',
          );
        }
      } catch (e) {
        _logger.error(
          'Error searching local star catalog: $e',
          source: 'Annotation',
        );
      }
    }

    // 2. Query SIMBAD for identification and basic data
    try {
      final simbadData = await _simbadProvider.queryByCoordinates(
        ra,
        dec,
        radiusArcmin: radiusArcmin,
      );
      if (simbadData != null) {
        // Merge with local data or use as base
        result = _mergeObjectData(result, simbadData);
      }
    } catch (e) {
      _logger.warning('SIMBAD query failed: $e', source: 'Annotation');
    }

    // 3. Query Gaia for stellar properties (if it looks like a star)
    if (result?.objectClass?.toLowerCase().contains('star') == true ||
        result == null) {
      try {
        final gaiaData = await _gaiaProvider.queryByCoordinates(ra, dec);
        if (gaiaData != null) {
          result = _mergeObjectData(result, gaiaData);
        }
      } catch (e) {
        _logger.warning('Gaia query failed: $e', source: 'Annotation');
      }
    }

    // 4. Check for Exoplanets (if it's a star)
    if (result != null && result.catalogIds != null) {
      // Try to find a name to query
      final name =
          result.catalogIds?['Name'] ??
          (result.catalogIds?['HD'] != null
              ? 'HD ${result.catalogIds!['HD']}'
              : null) ??
          result.simbadId;

      if (name != null) {
        try {
          final planets = await _exoplanetProvider.queryByStarName(name);
          if (planets.isNotEmpty) {
            result = result.copyWith(exoplanets: planets);
          }
        } catch (e) {
          _logger.warning('Exoplanet query failed: $e', source: 'Annotation');
        }
      }
    }

    return result;
  }
}
