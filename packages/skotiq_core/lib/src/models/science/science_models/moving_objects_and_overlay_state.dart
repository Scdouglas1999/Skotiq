part of '../science_models.dart';

/// Linking limits for moving-object detection. Positions are compared on the
/// sky, so the tolerances are in arcseconds, not pixels.
class MovingObjectOptions {
  /// How far a detection may sit from the straight-line prediction, and from a
  /// fixed source's position, and still count as the same object.
  final double matchToleranceArcsec;

  /// Fastest motion linked; faster objects trail into streaks the star
  /// detector does not report.
  final double maxRateArcsecPerMinute;

  /// Fewest frames a tracklet needs.
  final int minFrames;

  /// Recent frames of the session searched together.
  final int windowFrames;

  /// Cap on candidates reported per frame.
  final int maxCandidates;

  /// A tracklet whose detections all sit within this many pixels of one
  /// detector position is a sensor defect carried along by the dithers.
  final double pixelStaticTolerance;

  const MovingObjectOptions({
    this.matchToleranceArcsec = 2.0,
    this.maxRateArcsecPerMinute = 10.0,
    this.minFrames = 3,
    this.windowFrames = 8,
    this.maxCandidates = 25,
    this.pixelStaticTolerance = 1.5,
  });
}

/// One frame handed to moving-object detection, with the plate solve of that
/// frame (not of the frame that triggered the search).
class MovingObjectFrame {
  const MovingObjectFrame({
    required this.imagePath,
    required this.wcs,
    this.midExposureUtc,
  });

  final String imagePath;
  final WcsSolution wcs;

  /// Mid-exposure time; read from the FITS header when null.
  final DateTime? midExposureUtc;
}

class MovingObjectMatch {
  final String candidateId;
  final double raDegrees;
  final double decDegrees;
  final double motionArcsecPerMinute;
  final double positionAngleDegrees;
  final double confidence;
  final bool isKnownObject;
  final String? objectName;

  /// UTC mid-exposure time of the frame the reported RA/Dec was measured on
  /// (the newest frame of the window). Astrometric consumers (MPC export)
  /// must pair the position with this epoch. Null only when the frames
  /// carried no time; callers then fall back to the trigger frame's time.
  final DateTime? epochUtc;

  /// Measured flux (ADU) of the candidate on the frame its position comes
  /// from. Combined with the frame's photometric zero point this
  /// yields the apparent magnitude for the MPC report; null/zero means the
  /// report line stays astrometry-only.
  final double? fluxEstimate;

  /// Frames whose detections form the tracklet.
  final int frameCount;

  const MovingObjectMatch({
    required this.candidateId,
    required this.raDegrees,
    required this.decDegrees,
    required this.motionArcsecPerMinute,
    required this.positionAngleDegrees,
    required this.confidence,
    this.isKnownObject = false,
    this.objectName,
    this.epochUtc,
    this.fluxEstimate,
    this.frameCount = 0,
  });
}

class NarrowbandSet {
  final String hAlphaPath;
  final String oiiiPath;
  final String siiPath;

  const NarrowbandSet({
    required this.hAlphaPath,
    required this.oiiiPath,
    required this.siiPath,
  });
}

class LineRatioOptions {
  final double snrFloor;
  final bool continuumCorrection;
  final bool requireMatchingDimensions;

  const LineRatioOptions({
    this.snrFloor = 5.0,
    this.continuumCorrection = false,
    this.requireMatchingDimensions = true,
  });
}

class LineRatioMetric {
  final String label;
  final double value;

  const LineRatioMetric({required this.label, required this.value});
}

class LineRatioProduct {
  final DateTime createdAt;
  final List<LineRatioMetric> metrics;
  final Uint8List? previewImage;

  const LineRatioProduct({
    required this.createdAt,
    required this.metrics,
    this.previewImage,
  });
}

class ScienceModeState {
  final bool advancedModeEnabled;
  final bool overlayEnabled;
  final bool scienceHudVisible;
  final bool movingObjectModeEnabled;
  final bool differentialPhotometryActive;

  const ScienceModeState({
    this.advancedModeEnabled = false,
    this.overlayEnabled = true,
    this.scienceHudVisible = false,
    this.movingObjectModeEnabled = false,
    this.differentialPhotometryActive = false,
  });

  ScienceModeState copyWith({
    bool? advancedModeEnabled,
    bool? overlayEnabled,
    bool? scienceHudVisible,
    bool? movingObjectModeEnabled,
    bool? differentialPhotometryActive,
  }) {
    return ScienceModeState(
      advancedModeEnabled: advancedModeEnabled ?? this.advancedModeEnabled,
      overlayEnabled: overlayEnabled ?? this.overlayEnabled,
      scienceHudVisible: scienceHudVisible ?? this.scienceHudVisible,
      movingObjectModeEnabled:
          movingObjectModeEnabled ?? this.movingObjectModeEnabled,
      differentialPhotometryActive:
          differentialPhotometryActive ?? this.differentialPhotometryActive,
    );
  }
}

class ScienceOverlayState {
  final bool showPsfHeatmap;
  final bool showResidualVectors;
  final bool showMovingObjectTracks;
  final bool showUniformityMap;
  final bool showClipHighMap;
  final bool showClipLowMap;
  final bool showFwhmSurface;

  const ScienceOverlayState({
    this.showPsfHeatmap = false,
    this.showResidualVectors = false,
    this.showMovingObjectTracks = false,
    this.showUniformityMap = false,
    this.showClipHighMap = false,
    this.showClipLowMap = false,
    this.showFwhmSurface = false,
  });

  ScienceOverlayState copyWith({
    bool? showPsfHeatmap,
    bool? showResidualVectors,
    bool? showMovingObjectTracks,
    bool? showUniformityMap,
    bool? showClipHighMap,
    bool? showClipLowMap,
    bool? showFwhmSurface,
  }) {
    return ScienceOverlayState(
      showPsfHeatmap: showPsfHeatmap ?? this.showPsfHeatmap,
      showResidualVectors: showResidualVectors ?? this.showResidualVectors,
      showMovingObjectTracks:
          showMovingObjectTracks ?? this.showMovingObjectTracks,
      showUniformityMap: showUniformityMap ?? this.showUniformityMap,
      showClipHighMap: showClipHighMap ?? this.showClipHighMap,
      showClipLowMap: showClipLowMap ?? this.showClipLowMap,
      showFwhmSurface: showFwhmSurface ?? this.showFwhmSurface,
    );
  }
}
