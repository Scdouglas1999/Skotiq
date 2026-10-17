import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

part 'annotation_pipeline.dart';
part 'annotation_snr_tracker.dart';
part 'click_identify_service.dart';

/// Calculate angular distance between two points on a sphere (in degrees)
/// Uses the Haversine formula for better numerical stability
double _angularDistance(double ra1, double dec1, double ra2, double dec2) {
  // Convert to radians
  final ra1Rad = ra1 * math.pi / 180.0;
  final dec1Rad = dec1 * math.pi / 180.0;
  final ra2Rad = ra2 * math.pi / 180.0;
  final dec2Rad = dec2 * math.pi / 180.0;

  // Haversine formula
  final dRa = ra2Rad - ra1Rad;
  final dDec = dec2Rad - dec1Rad;

  final a =
      math.sin(dDec / 2) * math.sin(dDec / 2) +
      math.cos(dec1Rad) *
          math.cos(dec2Rad) *
          math.sin(dRa / 2) *
          math.sin(dRa / 2);

  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

  // Return distance in degrees
  return c * 180.0 / math.pi;
}

final annotationServiceProvider = Provider<AnnotationService>((ref) {
  final service = AnnotationService(ref, attachListeners: false);
  ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
    service.handleBackendChanged(previous, next);
  });
  ref.listen<CapturedImageData?>(currentImageProvider, (previous, next) {
    service.handleCurrentImageChanged(previous, next);
  });
  ref.listen<ImageStats?>(lastImageStatsProvider, (previous, next) {
    service.handleImageStatsChanged(previous, next);
  });
  return service;
});

final currentAnnotationProvider = StateProvider<ImageAnnotation?>(
  (ref) => null,
);

/// Status of the annotation processing pipeline
enum AnnotationStatus {
  idle,
  checkingCatalogs,
  plateSolving,
  searchingCatalogs,
  complete,
  error,
  catalogsNotInstalled,
  plateSolveFailed,
}

/// Current annotation processing state with status and message
class AnnotationState {
  final AnnotationStatus status;
  final String? message;
  final String? errorDetails;
  final int? objectsFound;

  const AnnotationState({
    this.status = AnnotationStatus.idle,
    this.message,
    this.errorDetails,
    this.objectsFound,
  });

  const AnnotationState.idle() : this();

  const AnnotationState.checking()
    : this(
        status: AnnotationStatus.checkingCatalogs,
        message: 'Checking catalogs...',
      );

  const AnnotationState.plateSolving()
    : this(status: AnnotationStatus.plateSolving, message: 'Plate solving...');

  const AnnotationState.searching()
    : this(
        status: AnnotationStatus.searchingCatalogs,
        message: 'Searching catalogs...',
      );

  AnnotationState.complete(int objects)
    : this(
        status: AnnotationStatus.complete,
        message: 'Found $objects objects',
        objectsFound: objects,
      );

  const AnnotationState.error(String error)
    : this(
        status: AnnotationStatus.error,
        message: 'Error',
        errorDetails: error,
      );

  const AnnotationState.catalogsNotInstalled()
    : this(
        status: AnnotationStatus.catalogsNotInstalled,
        message: 'No catalogs installed',
      );

  const AnnotationState.plateSolveFailed(String reason)
    : this(
        status: AnnotationStatus.plateSolveFailed,
        message: 'Plate solve failed',
        errorDetails: reason,
      );

  bool get isProcessing =>
      status == AnnotationStatus.checkingCatalogs ||
      status == AnnotationStatus.plateSolving ||
      status == AnnotationStatus.searchingCatalogs;
}

/// Provider for current annotation processing state
final annotationStateProvider = StateProvider<AnnotationState>(
  (ref) => const AnnotationState.idle(),
);

/// State for the SNR-based re-annotate suggestion banner
class ReAnnotateSuggestion {
  /// Whether to show the re-annotate banner
  final bool shouldShow;

  /// Percentage improvement in SNR since last annotation
  final double improvementPercent;

  const ReAnnotateSuggestion({
    this.shouldShow = false,
    this.improvementPercent = 0.0,
  });

  const ReAnnotateSuggestion.none() : this();
}

/// Provider that surfaces when re-annotation is suggested due to SNR improvement.
/// The annotation service updates this when SNR improves >40% since last annotation.
final reAnnotateSuggestionProvider = StateProvider<ReAnnotateSuggestion>(
  (ref) => const ReAnnotateSuggestion.none(),
);

/// Constants for SNR-based progressive annotation reveal
class _SnrAnnotationConstants {
  /// Base SNR value (minimum detectable) - objects only shown if SNR >= this
  static const double baseSnr = 3.0;

  /// Base magnitude limit when SNR is at baseSnr
  static const double baseMagnitude = 15.0;

  /// Maximum magnitude limit regardless of SNR
  static const double maxMagnitude = 20.0;

  /// Minimum SNR improvement ratio before re-annotating (20% improvement)
  static const double snrImprovementThreshold = 1.2;

  /// Minimum time between re-annotations (5 seconds)
  static const Duration reAnnotationDebounce = Duration(seconds: 5);

  /// Minimum SNR to even attempt annotation
  static const double minimumSnrThreshold = 2.0;
}

/// Service responsible for generating and managing image annotations.
///
/// The implementation is split across several part files:
/// - `annotation_pipeline.dart` — plate solve -> catalog search -> merge logic
/// - `annotation_snr_tracker.dart` — SNR monitoring and progressive reveal
/// - `click_identify_service.dart` — click-to-identify query logic
class AnnotationService {
  final Ref _ref;
  final CatalogManager _catalogManager;
  AnnotationCatalog? _annotationCatalog;
  String? _annotationCatalogPath;
  String? _dsoCatalogPath;

  /// Test-only override for the annotation catalog. When set,
  /// [_loadAnnotationCatalog] returns this instead of constructing one from the
  /// installed catalog files. Used to exercise the pipeline's genuine-failure
  /// path (e.g. a catalog whose `searchNearby` throws). Never set in production.
  @visibleForTesting
  AnnotationCatalog? debugAnnotationCatalogOverride;

  // External providers
  final _simbadProvider = SimbadProvider();
  final _exoplanetProvider = ExoplanetProvider();
  final _gaiaProvider = GaiaProvider();

  // Keep track of processed images to avoid duplicates
  String? _lastProcessedImagePath;
  int _annotationRunGeneration = 0;

  // SNR-based progressive annotation state
  double? _lastAnnotationSnr;
  double? _peakAnnotationSnr;
  DateTime? _lastAnnotationTime;
  double _currentSnrMagnitudeLimit = _SnrAnnotationConstants.baseMagnitude;
  PlateSolveData? _lastPlateSolve;
  final Set<String> _revealedObjectIds = {};

  LoggingService get _logger => _ref.read(loggingServiceProvider);

  AnnotationService(
    this._ref, {
    CatalogManager? catalogManager,
    bool attachListeners = true,
  }) : _catalogManager = catalogManager ?? CatalogManager.instance {
    if (attachListeners) {
      _attachListeners();
    }
  }

  void _attachListeners() {
    _ref.listen<CapturedImageData?>(
      currentImageProvider,
      handleCurrentImageChanged,
    );
    _ref.listen<ImageStats?>(lastImageStatsProvider, handleImageStatsChanged);
  }

  void handleCurrentImageChanged(
    CapturedImageData? previous,
    CapturedImageData? next,
  ) {
    if (next != null &&
        next.filePath != null &&
        next.filePath != _lastProcessedImagePath) {
      _lastProcessedImagePath = next.filePath;
      _lastAnnotationSnr = null;
      _peakAnnotationSnr = null;
      _lastAnnotationTime = null;
      _currentSnrMagnitudeLimit = _SnrAnnotationConstants.baseMagnitude;
      _revealedObjectIds.clear();

      // Clear stale annotations and suggestion banner
      _ref.read(currentAnnotationProvider.notifier).state = null;
      _ref.read(reAnnotateSuggestionProvider.notifier).state =
          const ReAnnotateSuggestion.none();
      _ref.read(annotationStateProvider.notifier).state =
          const AnnotationState.plateSolving();

      // Delegate to pipeline extension (annotation_pipeline.dart)
      processNewImage(next);
    }
  }

  void handleImageStatsChanged(ImageStats? previous, ImageStats? next) {
    if (next?.snr != null && _lastPlateSolve != null) {
      // Delegate to SNR tracker extension (annotation_snr_tracker.dart)
      checkSnrForReAnnotation(next!.snr!);
    }
  }

  void handleBackendChanged(SkotiqBackend? previous, SkotiqBackend next) {
    if (previous == null || identical(previous, next)) return;
    _annotationRunGeneration++;
    _lastProcessedImagePath = null;
    _lastAnnotationSnr = null;
    _peakAnnotationSnr = null;
    _lastAnnotationTime = null;
    _lastPlateSolve = null;
    _currentSnrMagnitudeLimit = _SnrAnnotationConstants.baseMagnitude;
    _revealedObjectIds.clear();
    _ref.read(currentAnnotationProvider.notifier).state = null;
    _ref.read(reAnnotateSuggestionProvider.notifier).state =
        const ReAnnotateSuggestion.none();
    _ref.read(annotationStateProvider.notifier).state =
        const AnnotationState.idle();
  }

  bool _isCurrentAnnotationRun(int generation, SkotiqBackend backend) =>
      generation == _annotationRunGeneration &&
      identical(_ref.read(backendProvider), backend);

  Stream<ImageAnnotation> get annotationStream => _ref
      .read(currentAnnotationProvider.notifier)
      .stream
      .where((a) => a != null)
      .cast<ImageAnnotation>();

  // Catalog & helper methods (kept in main file for shared access)

  Future<AnnotationCatalog?> _loadAnnotationCatalog() async {
    final override = debugAnnotationCatalogOverride;
    if (override != null) {
      return override;
    }

    final annotationStatus = await _catalogManager.getAnnotationCatalogStatus();
    if (!annotationStatus.isInstalled ||
        annotationStatus.installedPath == null) {
      return null;
    }

    final dsoStatus = await _catalogManager.getDsoCatalogStatus();
    final annotationPath = annotationStatus.installedPath!;
    final dsoPath = dsoStatus.installedPath;

    if (_annotationCatalog != null &&
        _annotationCatalogPath == annotationPath &&
        _dsoCatalogPath == dsoPath) {
      return _annotationCatalog;
    }

    final gladeLoader = GladePlusCatalogLoader(annotationPath);
    final ngcLoader = dsoPath != null ? OpenNgcCatalogLoader(dsoPath) : null;

    _annotationCatalog = AnnotationCatalog(
      ngcLoader: ngcLoader,
      gladeLoader: gladeLoader,
    );
    _annotationCatalogPath = annotationPath;
    _dsoCatalogPath = dsoPath;

    return _annotationCatalog;
  }

  ObjectType _mapAnnotationObjectType(AnnotationObjectType type) {
    switch (type) {
      case AnnotationObjectType.galaxy:
        return ObjectType.galaxy;
      case AnnotationObjectType.nebula:
      case AnnotationObjectType.emissionNebula:
      case AnnotationObjectType.reflectionNebula:
      case AnnotationObjectType.darkNebula:
      case AnnotationObjectType.hiiRegion:
        return ObjectType.nebula;
      case AnnotationObjectType.planetaryNebula:
        return ObjectType.planetaryNebula;
      case AnnotationObjectType.openCluster:
      case AnnotationObjectType.globularCluster:
      case AnnotationObjectType.starCluster:
        return ObjectType.starCluster;
      case AnnotationObjectType.doubleStar:
        return ObjectType.doubleStar;
      case AnnotationObjectType.asterism:
        return ObjectType.asterism;
      case AnnotationObjectType.supernovaRemnant:
      case AnnotationObjectType.other:
        return ObjectType.unknown;
    }
  }

  ObjectData _mergeObjectData(ObjectData? base, ObjectData new_) {
    if (base == null) return new_;

    return base.copyWith(
      description: base.description ?? new_.description,
      objectClass: base.objectClass ?? new_.objectClass,
      spectralType: base.spectralType ?? new_.spectralType,
      temperature: base.temperature ?? new_.temperature,
      mass: base.mass ?? new_.mass,
      radius: base.radius ?? new_.radius,
      luminosity: base.luminosity ?? new_.luminosity,
      distance: base.distance ?? new_.distance,
      parallax: base.parallax ?? new_.parallax,
      properMotion: base.properMotion ?? new_.properMotion,
      surfaceBrightness: base.surfaceBrightness ?? new_.surfaceBrightness,
      redshift: base.redshift ?? new_.redshift,
      morphology: base.morphology ?? new_.morphology,
      simbadId: base.simbadId ?? new_.simbadId,
      wikipediaUrl: base.wikipediaUrl ?? new_.wikipediaUrl,
      // Merge maps
      catalogIds: {...?base.catalogIds, ...?new_.catalogIds},
      dataSource: '${base.dataSource}, ${new_.dataSource}',
    );
  }

  ObjectType _inferObjectType(String? catalogType) {
    if (catalogType == null) return ObjectType.unknown;
    final lower = catalogType.toLowerCase();
    if (lower.contains('galaxy') || lower.contains('gx')) {
      return ObjectType.galaxy;
    }
    if (lower.contains('nebula') && lower.contains('planetary')) {
      return ObjectType.planetaryNebula;
    }
    if (lower.contains('nebula') || lower.contains('neb')) {
      return ObjectType.nebula;
    }
    if (lower.contains('cluster') && lower.contains('open')) {
      return ObjectType.starCluster;
    }
    if (lower.contains('cluster') && lower.contains('globular')) {
      return ObjectType.starCluster;
    }
    if (lower.contains('cluster')) return ObjectType.starCluster;
    if (lower.contains('double') || lower.contains('multiple')) {
      return ObjectType.doubleStar;
    }
    if (lower.contains('asterism')) return ObjectType.asterism;
    return ObjectType.unknown;
  }

  /// Parse spectral type from string to SpectralClass enum
  SpectralClass? _parseSpectralType(String? spectralType) {
    if (spectralType == null || spectralType.isEmpty) return null;

    final firstChar = spectralType[0].toLowerCase();
    switch (firstChar) {
      case 'o':
        return SpectralClass.o;
      case 'b':
        return SpectralClass.b;
      case 'a':
        return SpectralClass.a;
      case 'f':
        return SpectralClass.f;
      case 'g':
        return SpectralClass.g;
      case 'k':
        return SpectralClass.k;
      case 'm':
        return SpectralClass.m;
      default:
        return SpectralClass.unknown;
    }
  }

  /// Why a solve that reported success cannot be used, or null when it can.
  ///
  /// Annotation projects catalog coordinates through the solved centre and
  /// scale. Without both there is no field to search, so the catalog comes back
  /// empty for a reason that has nothing to do with what is up there.
  String? _unusableSolveGeometry(PlateSolveResult result) {
    if (!result.ra.isFinite || !result.dec.isFinite) {
      return 'Solver returned no field centre — the frame was not solved';
    }
    if (!result.pixelScale.isFinite || result.pixelScale <= 0) {
      return 'Solver returned no field scale — the frame was not solved; '
          'set the telescope focal length on the equipment profile so the '
          'solver is told the scale';
    }
    return null;
  }

  /// Convert a raw plate-solve error string into a user-facing description
  /// with actionable advice.
  String _describePlateSolveFailure(String? raw) {
    if (raw == null || raw.isEmpty) return 'Unknown plate solve error';

    final lower = raw.toLowerCase();

    // Solver not installed
    if (lower.contains('not found') || lower.contains('not installed')) {
      return 'Plate solver not installed \u2014 install ASTAP or configure a solver in Settings';
    }

    // Timeout
    if (lower.contains('timed out') || lower.contains('timeout')) {
      return 'Solver timed out \u2014 try a longer timeout, shorter exposure, or add coordinate hints from mount';
    }

    // Too few stars detected
    final starMatch = RegExp(
      r'(\d+)\s*stars?\s*(detected|found|extracted)',
      caseSensitive: false,
    ).firstMatch(raw);
    if (starMatch != null) {
      final count = int.tryParse(starMatch.group(1)!) ?? 0;
      if (count < 10) {
        return 'Too few stars ($count found, need 10+) \u2014 increase exposure time or check focus';
      }
    }
    if (lower.contains('no stars') || lower.contains('0 stars')) {
      return 'No stars detected \u2014 check focus, exposure length, and that the lens cap is off';
    }

    // No pattern match / no solution
    if (lower.contains('no match') ||
        lower.contains('no solution') ||
        lower.contains('could not solve') ||
        lower.contains('failed to match')) {
      return 'No pattern match \u2014 try a longer exposure, verify focus, or widen the search radius';
    }

    // WCS file missing (ASTAP-specific)
    if (lower.contains('no wcs file') || lower.contains('wcs file')) {
      return 'Solver did not produce a solution file \u2014 check ASTAP logs for details';
    }

    // Failed to run the executable
    if (lower.contains('failed to run')) {
      return 'Could not launch plate solver \u2014 verify the solver path in Settings';
    }

    // Backend/connection errors
    if (lower.contains('backend') && lower.contains('failed')) {
      return 'Backend plate solve failed \u2014 check connection and try again';
    }

    // Fall back to the raw error, trimmed
    final trimmed = raw.length > 120 ? '${raw.substring(0, 120)}...' : raw;
    return trimmed;
  }

  /// Convert a mount RA reading (HOURS, the ASCOM `RightAscension` /
  /// INDI `EQUATORIAL_EOD_COORD` convention) to the degrees a plate-solve
  /// hint expects.
  ///
  /// The unit is a contract, never inferred from the value: [0, 24] is the
  /// entire legal hours domain, so no range test can tell hours from degrees.
  ///
  /// Out-of-range input means a driver violated the contract. It is logged and
  /// passed through un-rescaled: a bad hint only costs solve time (solvers fall
  /// back to blind), while a silently rescaled one is indistinguishable from a
  /// correct hint.
  double _raHoursToSolverDegrees(double raHours) {
    if (!raHours.isFinite || raHours < 0.0 || raHours > 24.0) {
      _logger.warning(
        'Mount reported RA $raHours outside the legal 0-24h range; sending it '
        'to the solver without hour-to-degree conversion. The mount driver is '
        'not honouring the ASCOM RightAscension (hours) contract.',
        source: 'Annotation',
      );
      return ((raHours.isFinite ? raHours : 0.0) % 360.0 + 360.0) % 360.0;
    }
    return ((raHours * 15.0) % 360.0 + 360.0) % 360.0;
  }

  /// Generate a deduplication key for a celestial object annotation.
  ///
  /// Matches by catalog ID prefix (NGC, M, IC) case-insensitively, or by
  /// object name. This ensures that "NGC 224" from the annotation catalog
  /// and "NGC224" from the DSO catalog are treated as the same object.
  String _deduplicationKey(CelestialObjectAnnotation annotation) {
    // Try to extract a canonical catalog identifier
    final name = annotation.name.trim().toUpperCase();
    final catalogId = annotation.catalogId?.trim().toUpperCase() ?? '';

    // Parse common catalog prefixes: NGC, M, IC, PGC
    for (final source in [catalogId, name]) {
      final match = _catalogPrefixPattern.firstMatch(source);
      if (match != null) {
        final prefix = match.group(1)!.trim();
        final number = match.group(2)!.trim();
        return '${prefix}_$number';
      }
    }

    // Fall back to the name itself (normalized)
    return name.replaceAll(RegExp(r'\s+'), '_');
  }

  static final _catalogPrefixPattern = RegExp(
    r'^(NGC|M|IC|PGC|UGC|Ced|Sh2|Abell|Mel|Cr|Pal)\s*(\d+)',
    caseSensitive: false,
  );

  /// Merge two annotation objects, preferring the entry with more data.
  ///
  /// When both catalogs report the same object, keep the one with more
  /// populated optional fields (magnitude, size, common name). If tied,
  /// prefer [a] (the annotation catalog entry) since it may have merged data.
  CelestialObjectAnnotation _mergeAnnotationObjects(
    CelestialObjectAnnotation a,
    CelestialObjectAnnotation b,
  ) {
    int scoreA = 0;
    int scoreB = 0;
    if (a.magnitude != null) scoreA++;
    if (b.magnitude != null) scoreB++;
    if (a.size != null) scoreA++;
    if (b.size != null) scoreB++;
    if (a.commonName != null) scoreA++;
    if (b.commonName != null) scoreB++;
    if (a.catalogId != null) scoreA++;
    if (b.catalogId != null) scoreB++;
    if (a.detailedData != null) scoreA++;
    if (b.detailedData != null) scoreB++;

    // If b has strictly more fields, prefer it; otherwise keep a.
    if (scoreB > scoreA) return b;
    return a;
  }

  /// Manually trigger re-annotation on the current image.
  ///
  /// This resets internal state and re-runs the full annotation pipeline
  /// (plate solve + catalog search) on the currently displayed image.
  /// Call this when the user explicitly requests re-annotation.
  Future<void> reAnnotate() async {
    final image = _ref.read(currentImageProvider);
    if (image == null || image.filePath == null) {
      _logger.warning(
        'Cannot re-annotate: no current image',
        source: 'Annotation',
      );
      _ref.read(annotationStateProvider.notifier).state =
          const AnnotationState.error('No image loaded');
      return;
    }

    _logger.info(
      'Manual re-annotation triggered for: ${image.filePath}',
      source: 'Annotation',
    );

    // Reset progressive annotation state so we start fresh
    _lastProcessedImagePath = null;
    _lastAnnotationSnr = null;
    _peakAnnotationSnr = null;
    _lastAnnotationTime = null;
    _lastPlateSolve = null;
    _currentSnrMagnitudeLimit = _SnrAnnotationConstants.baseMagnitude;
    _revealedObjectIds.clear();

    // Dismiss the re-annotate suggestion banner
    _ref.read(reAnnotateSuggestionProvider.notifier).state =
        const ReAnnotateSuggestion.none();

    // Clear current annotation while processing
    _ref.read(currentAnnotationProvider.notifier).state = null;

    // Re-run the full pipeline (delegated to annotation_pipeline.dart)
    await processNewImage(image);
  }

  /// Export current annotation objects as CSV.
  /// Returns the CSV string content.
  String exportAnnotationsCsv() {
    final annotation = _ref.read(currentAnnotationProvider);
    if (annotation == null || annotation.objects.isEmpty) {
      throw StateError('No annotation data to export');
    }

    final buffer = StringBuffer();
    buffer.writeln(
      'Name,Common Name,Type,RA (deg),Dec (deg),RA (HMS),Dec (DMS),Magnitude,Size (arcmin)',
    );

    for (final obj in annotation.objects) {
      if (!obj.visible) continue;

      final raHours = obj.ra / 15.0;
      final raH = raHours.floor();
      final raM = ((raHours - raH) * 60).floor();
      final raS = (((raHours - raH) * 60 - raM) * 60);
      final raHms =
          '${raH.toString().padLeft(2, '0')}h${raM.toString().padLeft(2, '0')}m${raS.toStringAsFixed(1)}s';

      final decSign = obj.dec >= 0 ? '+' : '-';
      final absDec = obj.dec.abs();
      final decD = absDec.floor();
      final decM = ((absDec - decD) * 60).floor();
      final decS = (((absDec - decD) * 60 - decM) * 60);
      final decDms =
          "$decSign${decD.toString().padLeft(2, '0')}d${decM.toString().padLeft(2, '0')}m${decS.toStringAsFixed(1)}s";

      final name = _csvEscape(obj.name);
      final commonName = _csvEscape(obj.commonName ?? '');
      final typeName = _csvEscape(obj.type.name);
      final mag = obj.magnitude?.toStringAsFixed(2) ?? '';
      final size = obj.size?.toStringAsFixed(2) ?? '';

      buffer.writeln(
        '$name,$commonName,$typeName,${obj.ra.toStringAsFixed(6)},${obj.dec.toStringAsFixed(6)},$raHms,$decDms,$mag,$size',
      );
    }

    return buffer.toString();
  }

  /// Export current annotation objects as DS9 region file format.
  /// Returns the .reg file string content.
  String exportAnnotationsDs9Region() {
    final annotation = _ref.read(currentAnnotationProvider);
    if (annotation == null || annotation.objects.isEmpty) {
      throw StateError('No annotation data to export');
    }

    final buffer = StringBuffer();
    buffer.writeln('# Region file format: DS9 version 4.1');
    buffer.writeln(
      'global color=green dashlist=8 3 width=1 font="helvetica 10 normal roman" select=1 highlite=1 dash=0 fixed=0 edit=1 move=1 delete=1 include=1 source=1',
    );
    buffer.writeln('fk5');

    for (final obj in annotation.objects) {
      if (!obj.visible) continue;

      // Default radius: use object size if available, otherwise 30 arcseconds
      final radiusArcsec = (obj.size != null && obj.size! > 0)
          ? obj.size! *
                60.0 /
                2.0 // size is in arcminutes, need radius in arcsec
          : 30.0;

      final color = _ds9ColorForType(obj.type);
      final label = obj.commonName ?? obj.name;

      buffer.writeln(
        'circle(${obj.ra.toStringAsFixed(6)},${obj.dec.toStringAsFixed(6)},${radiusArcsec.toStringAsFixed(1)}") # color=$color text={$label}',
      );
    }

    return buffer.toString();
  }

  String _ds9ColorForType(ObjectType type) {
    switch (type) {
      case ObjectType.galaxy:
        return 'yellow';
      case ObjectType.nebula:
        return 'magenta';
      case ObjectType.planetaryNebula:
        return 'cyan';
      case ObjectType.starCluster:
        return 'green';
      case ObjectType.star:
      case ObjectType.doubleStar:
        return 'white';
      default:
        return 'red';
    }
  }

  String _csvEscape(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }
}
