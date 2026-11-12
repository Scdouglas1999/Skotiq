import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/remote_host.dart';
import '../backend/skotiq_backend.dart';
import '../models/annotation_data.dart';
import '../models/annotation_settings.dart';
import '../models/imaging/imaging_models.dart';
import '../providers/annotation_settings_provider.dart';
import '../providers/backend_provider.dart';
import '../providers/equipment/mount_state_provider.dart';
import '../providers/imaging_provider.dart';
import 'catalog_lookup/exoplanet_provider.dart';
import 'catalog_lookup/gaia_provider.dart';
import 'catalog_lookup/simbad_provider.dart';
import 'imaging_service.dart';
import 'logging_service.dart';
import 'plate_solve_service.dart';
import 'wcs/plate_solve_data_from_result.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

part 'annotation_pipeline.dart';
part 'annotation_snr_tracker.dart';
part 'click_identify_service.dart';

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

final annotationStateProvider = StateProvider<AnnotationState>(
  (ref) => const AnnotationState.idle(),
);

/// State for the SNR-based re-annotate suggestion banner
class ReAnnotateSuggestion {
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
  OpenNgcDsoCatalog? _ngcLoader;

  /// Test-only override for the annotation catalog. When set,
  /// [_loadAnnotationCatalog] returns this instead of constructing one from the
  /// installed catalog files. Used to exercise the pipeline's genuine-failure
  /// path (e.g. a catalog whose `searchNearby` throws). Never set in production.
  @visibleForTesting
  AnnotationCatalog? debugAnnotationCatalogOverride;

  final _simbadProvider = SimbadProvider();
  final _exoplanetProvider = ExoplanetProvider();
  final _gaiaProvider = GaiaProvider();

  // Keep track of processed images to avoid duplicates
  String? _lastProcessedImagePath;
  int _annotationRunGeneration = 0;

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

      processNewImage(next);
    }
  }

  void handleImageStatsChanged(ImageStats? previous, ImageStats? next) {
    if (next?.snr != null && _lastPlateSolve != null) {
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

    final annotationStatus = await _catalogManager.status(
      SkyCatalog.annotation,
    );
    final annotationPath = annotationStatus.installedPath;
    if (annotationPath == null) return null;

    final dsoStatus = await _catalogManager.status(SkyCatalog.dso);
    final ngcLoader = dsoStatus.isInstalled ? _catalogManager.dsos : null;

    if (_annotationCatalog != null &&
        _annotationCatalogPath == annotationPath &&
        identical(_ngcLoader, ngcLoader)) {
      return _annotationCatalog;
    }

    final gladeLoader = GladePlusCatalogLoader(annotationPath);

    _annotationCatalog = AnnotationCatalog(
      ngcLoader: ngcLoader,
      gladeLoader: gladeLoader,
    );
    _annotationCatalogPath = annotationPath;
    _ngcLoader = ngcLoader;

    return _annotationCatalog;
  }

  /// The overlay group a catalog object type is drawn and filtered as.
  ObjectType _objectTypeFor(DsoType type) => switch (type) {
    DsoType.galaxy ||
    DsoType.galaxyPair ||
    DsoType.galaxyTriplet ||
    DsoType.galaxyGroup => ObjectType.galaxy,
    DsoType.nebula ||
    DsoType.emissionNebula ||
    DsoType.reflectionNebula ||
    DsoType.darkNebula ||
    DsoType.hiiRegion => ObjectType.nebula,
    DsoType.planetaryNebula => ObjectType.planetaryNebula,
    DsoType.openCluster ||
    DsoType.globularCluster ||
    DsoType.clusterWithNebulosity => ObjectType.starCluster,
    DsoType.doubleStar => ObjectType.doubleStar,
    DsoType.association => ObjectType.asterism,
    DsoType.supernova ||
    DsoType.star ||
    DsoType.nova ||
    DsoType.starCloud ||
    DsoType.asterism ||
    DsoType.other => ObjectType.unknown,
  };

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
      return 'Solver returned no field center — the frame was not solved';
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

    if (lower.contains('failed to run')) {
      return 'Could not launch plate solver \u2014 verify the solver path in Settings';
    }

    if (lower.contains('backend') && lower.contains('failed')) {
      return 'Backend plate solve failed \u2014 check connection and try again';
    }

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
        'not honoring the ASCOM RightAscension (hours) contract.',
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

    _lastProcessedImagePath = null;
    _lastAnnotationSnr = null;
    _peakAnnotationSnr = null;
    _lastAnnotationTime = null;
    _lastPlateSolve = null;
    _currentSnrMagnitudeLimit = _SnrAnnotationConstants.baseMagnitude;
    _revealedObjectIds.clear();

    _ref.read(reAnnotateSuggestionProvider.notifier).state =
        const ReAnnotateSuggestion.none();

    // Clear current annotation while processing
    _ref.read(currentAnnotationProvider.notifier).state = null;

    await processNewImage(image);
  }
}
