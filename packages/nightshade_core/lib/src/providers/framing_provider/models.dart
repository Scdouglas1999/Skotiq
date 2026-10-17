part of '../framing_provider.dart';

// Framing state

/// State of the framing assistant
class FramingState {
  /// Selected target information
  final FramingTarget? target;

  /// Rich planning source for [target], when the target came from Plan Tonight
  /// or suggestions. Preserved so Framing can round-trip into Smart Night
  /// sequence generation without degrading to name/coordinate-only metadata.
  final TargetSuggestion? sourceSuggestion;

  /// Absolute sky coordinates the FOV reticle is aimed at: where the telescope
  /// will actually be pointed (and the mosaic capture plan is centered).
  ///
  /// `null` means the aim coincides with [target] — the reticle sits at the
  /// view center, which is the default before any FOV-box drag and preserves
  /// the long-standing "box glued to canvas center" behavior bit-for-bit.
  ///
  /// Why a separate field rather than folding the offset into [target]: the
  /// target doubles as the *view center* — the sky point the survey cutout was
  /// fetched around and the projection origin every painter shares. Moving the
  /// reticle must not move the view center (that would slide the sky under the
  /// box, the bug this fixes), so the aim is kept as absolute sky and the view
  /// is free to pan underneath it — including `_recenterFromPan`, which shifts
  /// [target] while the aim correctly stays put on the sky.
  final double? aimRaHours;

  /// Declination half of the aim point; always set/cleared together with
  /// [aimRaHours].
  final double? aimDecDegrees;

  /// Survey source for background image
  final SurveySource surveySource;

  /// Loaded survey image
  final Uint8List? surveyImageBytes;

  /// Decoded survey image for display
  final ui.Image? surveyImage;

  /// Astrometric registration linkage for the currently-loaded survey image.
  ///
  /// Populated whenever a survey cutout is successfully loaded (from network or
  /// cache). It pairs the *angular field of view that was requested* with the
  /// *actual decoded pixel dimensions* of the returned image, which is the one
  /// authoritative scale every framing painter and gesture handler projects
  /// through (see [FramingPlateScale]). `null` whenever no image is loaded.
  final FramingPlateScale? plateScale;

  /// Is the survey image loading?
  final bool isLoadingImage;

  /// Error message if image failed to load
  final String? imageError;

  /// Frame rotation in degrees
  final double rotation;

  /// Zoom level (1.0 = 100%)
  final double zoom;

  /// Pan offset in pixels
  final double panX;
  final double panY;

  /// Display options
  final bool showGrid;
  final bool showLabels;
  final bool showCardinalDirections;

  /// Whether to overlay candidate guide stars (bright catalog stars inside the
  /// FOV that an autoguider could lock onto).
  final bool showGuideStars;

  /// Custom equipment (null = use active profile)
  final FramingEquipment? customEquipment;

  /// Whether we're using custom equipment vs profile
  final bool useCustomEquipment;

  /// User-specified preview FOV for browsing without equipment (degrees)
  final double previewFovDegrees;

  /// Equipment FOV overlay opacity (0.0-1.0) - used when preview > equipment FOV
  final double equipmentFovOverlayOpacity;

  /// Whether to show equipment FOV overlay when preview FOV is larger
  final bool showEquipmentFovOverlay;

  /// Whether mosaic mode is enabled
  final bool mosaicEnabled;

  /// Mosaic configuration
  final FramingMosaicConfig mosaicConfig;

  /// Generated mosaic panels (computed from config and target)
  final List<FramingMosaicPanel> mosaicPanels;

  /// Currently selected panel index (-1 = none)
  final int selectedPanelIndex;

  /// Whether to show panel numbers on the overlay
  final bool showPanelNumbers;

  /// Whether to highlight the capture sequence path
  final bool showSequencePath;

  /// Whether to show the optical config overlay panel on the framing canvas
  final bool showOpticalConfigPanel;

  const FramingState({
    this.target,
    this.sourceSuggestion,
    this.aimRaHours,
    this.aimDecDegrees,
    this.surveySource = SurveySource.dss2Red,
    this.surveyImageBytes,
    this.surveyImage,
    this.plateScale,
    this.isLoadingImage = false,
    this.imageError,
    this.rotation = 0,
    this.zoom = 1.0,
    this.panX = 0,
    this.panY = 0,
    this.showGrid = true,
    this.showLabels = true,
    this.showCardinalDirections = true,
    this.showGuideStars = false,
    this.customEquipment,
    this.useCustomEquipment = false,
    this.previewFovDegrees = 2.0,
    this.equipmentFovOverlayOpacity = 0.3,
    this.showEquipmentFovOverlay = true,
    this.mosaicEnabled = false,
    this.mosaicConfig = const FramingMosaicConfig(),
    this.mosaicPanels = const [],
    this.selectedPanelIndex = -1,
    this.showPanelNumbers = true,
    this.showSequencePath = true,
    this.showOpticalConfigPanel = false,
  });

  /// RA in hours the FOV reticle is aimed at: the explicit [aimRaHours] when
  /// the user has dragged the box off-center, else the view-center [target]'s
  /// RA. `null` when no target is framed.
  double? get effectiveAimRaHours => aimRaHours ?? target?.raHours;

  /// Dec counterpart of [effectiveAimRaHours].
  double? get effectiveAimDecDegrees => aimDecDegrees ?? target?.decDegrees;

  /// Where the telescope will actually point: the picked [target]'s identity
  /// (name, catalog id, photometry) carried on the AIM's coordinates.
  ///
  /// Pointing consumers — slew/GoTo, add-to-sequence, the solve hint, the
  /// on-canvas coordinate card — should read this rather than [target], whose
  /// coordinates are the *view center* (what the survey cutout is centered on),
  /// which only coincides with the aim when the box has not been dragged.
  FramingTarget? get effectiveAimTarget {
    final t = target;
    if (t == null) return null;
    final ra = aimRaHours;
    final dec = aimDecDegrees;
    if (ra == null || dec == null) return t;
    return FramingTarget(
      name: t.name,
      catalogId: t.catalogId,
      raHours: ra,
      decDegrees: dec,
      type: t.type,
      objectType: t.objectType,
      magnitude: t.magnitude,
      sizeArcmin: t.sizeArcmin,
      constellation: t.constellation,
    );
  }

  FramingState copyWith({
    FramingTarget? target,
    TargetSuggestion? sourceSuggestion,
    double? aimRaHours,
    double? aimDecDegrees,
    SurveySource? surveySource,
    Uint8List? surveyImageBytes,
    ui.Image? surveyImage,
    FramingPlateScale? plateScale,
    bool? isLoadingImage,
    String? imageError,
    double? rotation,
    double? zoom,
    double? panX,
    double? panY,
    bool? showGrid,
    bool? showLabels,
    bool? showCardinalDirections,
    bool? showGuideStars,
    FramingEquipment? customEquipment,
    bool? useCustomEquipment,
    double? previewFovDegrees,
    double? equipmentFovOverlayOpacity,
    bool? showEquipmentFovOverlay,
    bool? mosaicEnabled,
    FramingMosaicConfig? mosaicConfig,
    List<FramingMosaicPanel>? mosaicPanels,
    int? selectedPanelIndex,
    bool? showPanelNumbers,
    bool? showSequencePath,
    bool? showOpticalConfigPanel,
    bool clearImage = false,
    bool clearTarget = false,
    bool clearSourceSuggestion = false,
    bool clearAim = false,
  }) {
    return FramingState(
      target: clearTarget ? null : (target ?? this.target),
      sourceSuggestion: clearTarget || clearSourceSuggestion
          ? null
          : (sourceSuggestion ?? this.sourceSuggestion),
      // An orphaned aim (no target to hang it off of) is meaningless — and
      // would silently re-apply its offset to the NEXT target picked — so
      // clearing the target always clears the aim too.
      aimRaHours: (clearAim || clearTarget)
          ? null
          : (aimRaHours ?? this.aimRaHours),
      aimDecDegrees: (clearAim || clearTarget)
          ? null
          : (aimDecDegrees ?? this.aimDecDegrees),
      surveySource: surveySource ?? this.surveySource,
      surveyImageBytes: clearImage
          ? null
          : (surveyImageBytes ?? this.surveyImageBytes),
      surveyImage: clearImage ? null : (surveyImage ?? this.surveyImage),
      plateScale: clearImage ? null : (plateScale ?? this.plateScale),
      isLoadingImage: isLoadingImage ?? this.isLoadingImage,
      imageError: clearImage ? null : imageError,
      rotation: rotation ?? this.rotation,
      zoom: zoom ?? this.zoom,
      panX: panX ?? this.panX,
      panY: panY ?? this.panY,
      showGrid: showGrid ?? this.showGrid,
      showLabels: showLabels ?? this.showLabels,
      showCardinalDirections:
          showCardinalDirections ?? this.showCardinalDirections,
      showGuideStars: showGuideStars ?? this.showGuideStars,
      customEquipment: customEquipment ?? this.customEquipment,
      useCustomEquipment: useCustomEquipment ?? this.useCustomEquipment,
      previewFovDegrees: previewFovDegrees ?? this.previewFovDegrees,
      equipmentFovOverlayOpacity:
          equipmentFovOverlayOpacity ?? this.equipmentFovOverlayOpacity,
      showEquipmentFovOverlay:
          showEquipmentFovOverlay ?? this.showEquipmentFovOverlay,
      mosaicEnabled: mosaicEnabled ?? this.mosaicEnabled,
      mosaicConfig: mosaicConfig ?? this.mosaicConfig,
      mosaicPanels: mosaicPanels ?? this.mosaicPanels,
      selectedPanelIndex: selectedPanelIndex ?? this.selectedPanelIndex,
      showPanelNumbers: showPanelNumbers ?? this.showPanelNumbers,
      showSequencePath: showSequencePath ?? this.showSequencePath,
      showOpticalConfigPanel:
          showOpticalConfigPanel ?? this.showOpticalConfigPanel,
    );
  }
}

/// Target information for framing
class FramingTarget {
  final String name;
  final String? catalogId;
  final double raHours;
  final double decDegrees;
  final TargetType? type;

  /// Catalog subtype retained for filter selection (e.g. emission vs reflection).
  final String? objectType;
  final double? magnitude;
  final double? sizeArcmin;
  final String? constellation;

  const FramingTarget({
    required this.name,
    this.catalogId,
    required this.raHours,
    required this.decDegrees,
    this.type,
    this.objectType,
    this.magnitude,
    this.sizeArcmin,
    this.constellation,
  });

  /// RA in degrees
  double get raDegrees => raHours * 15;

  /// Format RA as HH:MM:SS
  String get raFormatted {
    final hours = raHours.floor();
    final minutes = ((raHours - hours) * 60).floor();
    final seconds = (((raHours - hours) * 60 - minutes) * 60).round();
    return '${hours.toString().padLeft(2, '0')}h ${minutes.toString().padLeft(2, '0')}m ${seconds.toString().padLeft(2, '0')}s';
  }

  /// Format Dec as ±DD°MM'SS"
  String get decFormatted {
    final sign = decDegrees >= 0 ? '+' : '-';
    final absDec = decDegrees.abs();
    final degrees = absDec.floor();
    final minutes = ((absDec - degrees) * 60).floor();
    final seconds = (((absDec - degrees) * 60 - minutes) * 60).round();
    return '$sign${degrees.toString().padLeft(2, '0')}° ${minutes.toString().padLeft(2, '0')}\' ${seconds.toString().padLeft(2, '0')}"';
  }

  factory FramingTarget.fromCelestialTarget(CelestialTarget t) {
    return FramingTarget(
      name: t.name,
      catalogId: t.catalogId,
      raHours: t.raHours,
      decDegrees: t.decDegrees,
      type: t.objectType,
      magnitude: t.magnitude,
      sizeArcmin: t.sizeArcmin,
      constellation: t.constellation,
    );
  }

  /// Serializes this target for single-key settings persistence
  /// (`framing.lastTarget`). Used to remember the last framed target across
  /// app restarts WITHOUT writing a row into the `targets` library table.
  Map<String, dynamic> toJson() => {
    'name': name,
    if (catalogId != null) 'catalogId': catalogId,
    'raHours': raHours,
    'decDegrees': decDegrees,
    if (type != null) 'type': type!.name,
    if (objectType != null) 'objectType': objectType,
    if (magnitude != null) 'magnitude': magnitude,
    if (sizeArcmin != null) 'sizeArcmin': sizeArcmin,
    if (constellation != null) 'constellation': constellation,
  };

  /// Reconstructs a target previously written by [toJson]. Returns null when
  /// the payload is missing required fields so the caller can fail closed
  /// rather than fabricate a bogus target.
  static FramingTarget? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final raHours = (json['raHours'] as num?)?.toDouble();
    final decDegrees = (json['decDegrees'] as num?)?.toDouble();
    if (name is! String ||
        name.isEmpty ||
        raHours == null ||
        decDegrees == null) {
      return null;
    }
    final typeName = json['type'] as String?;
    return FramingTarget(
      name: name,
      catalogId: json['catalogId'] as String?,
      objectType: json['objectType'] as String?,
      // Backward-compat: older payloads may have stored RA in degrees.
      raHours: _normalizeRaHoursMaybeDegrees(raHours),
      decDegrees: decDegrees,
      type: typeName != null
          ? TargetType.values.firstWhere(
              (t) => t.name == typeName,
              orElse: () => TargetType.other,
            )
          : null,
      magnitude: (json['magnitude'] as num?)?.toDouble(),
      sizeArcmin: (json['sizeArcmin'] as num?)?.toDouble(),
      constellation: json['constellation'] as String?,
    );
  }
}

TargetType? _targetTypeFromSuggestion(String? objectType) {
  final normalized = objectType?.toLowerCase().trim();
  if (normalized == null || normalized.isEmpty) return null;
  if (normalized.contains('galaxy')) return TargetType.galaxy;
  if (normalized.contains('nebula')) return TargetType.nebula;
  if (normalized.contains('cluster')) return TargetType.cluster;
  if (normalized.contains('star')) return TargetType.star;
  if (normalized.contains('planet')) return TargetType.planet;
  if (normalized.contains('moon')) return TargetType.moon;
  if (normalized.contains('comet')) return TargetType.comet;
  if (normalized.contains('asteroid')) return TargetType.asteroid;
  return TargetType.other;
}

/// Custom equipment configuration for framing
class FramingEquipment {
  final String cameraName;
  final double sensorWidthMm;
  final double sensorHeightMm;
  final double pixelSizeMicrons;
  final int pixelsX;
  final int pixelsY;

  final String telescopeName;
  final double focalLengthMm;
  final double apertureMm;

  final double focalReducer;

  const FramingEquipment({
    required this.cameraName,
    required this.sensorWidthMm,
    required this.sensorHeightMm,
    required this.pixelSizeMicrons,
    required this.pixelsX,
    required this.pixelsY,
    required this.telescopeName,
    required this.focalLengthMm,
    required this.apertureMm,
    this.focalReducer = 1.0,
  });

  double get effectiveFocalLength => focalLengthMm * focalReducer;

  /// FOV width in degrees
  double get fovWidthDeg {
    final fovRad = 2 * math.atan(sensorWidthMm / (2 * effectiveFocalLength));
    return fovRad * 180 / math.pi;
  }

  /// FOV height in degrees
  double get fovHeightDeg {
    final fovRad = 2 * math.atan(sensorHeightMm / (2 * effectiveFocalLength));
    return fovRad * 180 / math.pi;
  }

  /// Image scale in arcsec/pixel
  double get imageScale {
    final pixelSizeMm = pixelSizeMicrons / 1000;
    return (pixelSizeMm / effectiveFocalLength) * 206265;
  }

  double get focalRatio => effectiveFocalLength / apertureMm;
}

/// Survey image sources
enum SurveySource {
  dss2Red('DSS2 Red', 'DSS2R'),
  dss2Blue('DSS2 Blue', 'DSS2B'),
  dss2IR('DSS2 IR', 'DSS2IR'),
  sdss('SDSS Color', 'SDSSg'),
  twomassJ('2MASS J', '2MASSJ'),
  twomassH('2MASS H', '2MASSH'),
  twomassK('2MASS K', '2MASSK'),
  wise12('WISE 12μm', 'WISE12');

  final String displayName;
  final String surveyCode;

  const SurveySource(this.displayName, this.surveyCode);
}

// Mosaic support

/// Configuration for a mosaic pattern in the framing assistant.
///
/// Distinct from `MosaicConfig` in `services/mosaic_service.dart`, which
/// describes mosaic geometry in arcminutes/degrees for sequence generation.
/// This UI-facing version is grid-based (columns/rows/overlapPercent).
class FramingMosaicConfig {
  /// Number of horizontal panels
  final int columns;

  /// Number of vertical panels
  final int rows;

  /// Overlap percentage between panels (0-50%)
  final double overlapPercent;

  /// Whether to use a serpentine (snake) capture pattern
  final bool serpentine;

  /// Starting corner for capture sequence
  final MosaicStartCorner startCorner;

  /// Custom panel rotation for each panel (null = use global rotation)
  final double? panelRotation;

  const FramingMosaicConfig({
    this.columns = 2,
    this.rows = 2,
    this.overlapPercent = 15.0,
    this.serpentine = true,
    this.startCorner = MosaicStartCorner.topLeft,
    this.panelRotation,
  });

  FramingMosaicConfig copyWith({
    int? columns,
    int? rows,
    double? overlapPercent,
    bool? serpentine,
    MosaicStartCorner? startCorner,
    double? panelRotation,
  }) {
    return FramingMosaicConfig(
      columns: columns ?? this.columns,
      rows: rows ?? this.rows,
      overlapPercent: overlapPercent ?? this.overlapPercent,
      serpentine: serpentine ?? this.serpentine,
      startCorner: startCorner ?? this.startCorner,
      panelRotation: panelRotation ?? this.panelRotation,
    );
  }

  /// Total number of panels
  int get totalPanels => columns * rows;

  /// Effective FOV multiplier accounting for overlap
  double get effectiveWidthMultiplier =>
      columns - (columns - 1) * (overlapPercent / 100);
  double get effectiveHeightMultiplier =>
      rows - (rows - 1) * (overlapPercent / 100);
}

/// Starting corner for mosaic capture
enum MosaicStartCorner { topLeft, topRight, bottomLeft, bottomRight }

/// Individual panel in a framing-assistant mosaic.
///
/// Distinct from `MosaicPanel` in `services/mosaic_service.dart`, which is the
/// service-layer geometry representation used by `MosaicService`.
class FramingMosaicPanel {
  /// Panel index (0-based, in capture order)
  final int index;

  /// Grid column (0-based)
  final int column;

  /// Grid row (0-based)
  final int row;

  /// Center RA in hours
  final double centerRaHours;

  /// Center Dec in degrees
  final double centerDecDegrees;

  /// Panel name (e.g., "Panel 1 (0,0)")
  final String name;

  /// Whether this panel has been captured
  final bool isCaptured;

  const FramingMosaicPanel({
    required this.index,
    required this.column,
    required this.row,
    required this.centerRaHours,
    required this.centerDecDegrees,
    required this.name,
    this.isCaptured = false,
  });

  FramingMosaicPanel copyWith({
    int? index,
    int? column,
    int? row,
    double? centerRaHours,
    double? centerDecDegrees,
    String? name,
    bool? isCaptured,
  }) {
    return FramingMosaicPanel(
      index: index ?? this.index,
      column: column ?? this.column,
      row: row ?? this.row,
      centerRaHours: centerRaHours ?? this.centerRaHours,
      centerDecDegrees: centerDecDegrees ?? this.centerDecDegrees,
      name: name ?? this.name,
      isCaptured: isCaptured ?? this.isCaptured,
    );
  }

  /// Format center RA as HH:MM:SS
  String get raFormatted {
    final hours = centerRaHours.floor();
    final minutes = ((centerRaHours - hours) * 60).floor();
    final seconds = (((centerRaHours - hours) * 60 - minutes) * 60).round();
    return '${hours.toString().padLeft(2, '0')}h ${minutes.toString().padLeft(2, '0')}m ${seconds.toString().padLeft(2, '0')}s';
  }

  /// Format center Dec as ±DD°MM'SS"
  String get decFormatted {
    final sign = centerDecDegrees >= 0 ? '+' : '-';
    final absDec = centerDecDegrees.abs();
    final degrees = absDec.floor();
    final minutes = ((absDec - degrees) * 60).floor();
    final seconds = (((absDec - degrees) * 60 - minutes) * 60).round();
    return '$sign${degrees.toString().padLeft(2, '0')}° ${minutes.toString().padLeft(2, '0')}\' ${seconds.toString().padLeft(2, '0')}"';
  }
}
