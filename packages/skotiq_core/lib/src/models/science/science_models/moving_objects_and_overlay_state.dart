part of '../science_models.dart';

class MovingObjectOptions {
  final double minMotionPixels;
  final double maxMotionPixels;

  const MovingObjectOptions({
    this.minMotionPixels = 1.5,
    this.maxMotionPixels = 18.0,
  });
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

  /// UTC epoch the reported RA/Dec corresponds to. The detector reports the
  /// *midpoint* position between the first and last frame of the stack, so
  /// this is the midpoint of their DATE-OBS values — not the capture time of
  /// the frame that triggered detection. Astrometric consumers (MPC export)
  /// must pair the position with this epoch or fast movers pick up an error
  /// of motion × (half the stack baseline). Null when the frames carried no
  /// parseable DATE-OBS; callers then fall back to the trigger frame's time.
  final DateTime? epochUtc;

  /// Mean measured flux (ADU) of the candidate across the first/last
  /// detections. Combined with the frame's photometric zero point this
  /// yields the apparent magnitude for the MPC report; null/zero means the
  /// report line stays astrometry-only.
  final double? fluxEstimate;

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
