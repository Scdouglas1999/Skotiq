part of '../framing_provider.dart';

class FramingState {
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

  final bool isLoadingImage;

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

  final bool useCustomEquipment;

  /// User-specified preview FOV for browsing without equipment (degrees)
  final double previewFovDegrees;

  /// Equipment FOV overlay opacity (0.0-1.0) - used when preview > equipment FOV
  final double equipmentFovOverlayOpacity;

  /// Whether to show equipment FOV overlay when preview FOV is larger
  final bool showEquipmentFovOverlay;

  final bool mosaicEnabled;

  final FramingMosaicConfig mosaicConfig;

  /// Generated mosaic panels (computed from config and target)
  final List<FramingMosaicPanel> mosaicPanels;

  /// Currently selected panel index (-1 = none)
  final int selectedPanelIndex;

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
