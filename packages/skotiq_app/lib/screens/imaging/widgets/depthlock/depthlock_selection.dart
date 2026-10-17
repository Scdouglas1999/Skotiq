import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import 'package:skotiq_core/skotiq_core.dart';

import 'depthlock_geometry.dart';
import 'depthlock_presentation.dart';
import 'depthlock_presets.dart';

/// What the imaging screen can offer DepthLock right now: which file the
/// displayed frame is, what anchors it to the sky, and what — if anything —
/// stands in the way of marking a region on it.
@immutable
class DepthLockSelection {
  const DepthLockSelection({
    this.referencePath,
    this.capturedImageId,
    this.wcs,
    this.geometry,
    this.imageSize,
    this.blocker,
    this.advisory,
    this.isLiveStackReference = false,
  });

  /// The displayed frame's file on disk. DepthLock reads its header itself,
  /// so this is the only thing the create path strictly needs.
  final String? referencePath;

  /// The `captured_images` row id for that file, when the session knows it.
  /// The goal's target identity and the overlay's astrometry both hang off it.
  final int? capturedImageId;

  /// The frame's plate solve as Skotiq recorded it. Needed to DRAW saved
  /// goals over this frame, and used as the geometry fallback when the file's
  /// own header carries no TAN solution.
  final SolvedWcs? wcs;

  /// The TAN solution saved goals are DRAWN through: Skotiq's plate solve
  /// for the frame when it has one, else the file's own header solution. The
  /// stack canvas gets it from its reference sub's header when the sub was
  /// never solved, which is why drawing does not require a database row.
  final ReferenceGeometry? geometry;

  final Size? imageSize;

  /// One sentence saying why a region cannot be marked at all, or null.
  final String? blocker;

  /// One sentence about something the operator should know but that does not
  /// stop them, or null.
  final String? advisory;

  /// The frame on screen is the sub a running live stack is aligned to.
  ///
  /// This is the only frame on which "mark it on the stack" is a coherent
  /// request: the stack itself is a registered, scaled composite with no
  /// header of its own, and every frame it holds is registered to THIS sub.
  /// A region drawn on any other sub belongs to that sub's pixels.
  final bool isLiveStackReference;

  bool get canSelect => referencePath != null && blocker == null;
}

/// Resolve [DepthLockSelection] from what the imaging screen is showing.
final depthLockSelectionProvider = Provider<DepthLockSelection>((ref) {
  final image = ref.watch(currentImageProvider);
  final stack = ref.watch(liveStackingProvider);
  final String? stackReference = stack.status == LiveStackingStatus.running &&
          (stack.referenceImagePath?.trim().isNotEmpty ?? false)
      ? stack.referenceImagePath!.trim()
      : null;

  if (image == null) {
    return DepthLockSelection(
      blocker: stackReference == null
          ? 'No frame is on screen. Capture or open a sub, then mark the '
              'region on it.'
          // The stack is a registered composite with no header and no
          // calibration of its own, so it can never be a goal's reference.
          // Its reference sub can, and that is a file the operator can open.
          : 'A live stack is running on ${p.basename(stackReference)}. Open '
              'that sub in the viewer to mark a region on it — the stack '
              'itself is not a calibrated light and cannot anchor a goal.',
    );
  }
  final Size size = Size(image.width.toDouble(), image.height.toDouble());
  final String? path = image.filePath;
  if (path == null || path.trim().isEmpty) {
    return DepthLockSelection(
      imageSize: size,
      blocker: 'This preview is not a file on disk, so there is nothing for '
          'DepthLock to re-read. Save the sub, or open one from the session '
          'frames.',
    );
  }
  if (image.isColor) {
    return DepthLockSelection(
      referencePath: path,
      imageSize: size,
      blocker: 'DepthLock measures monochrome, linear data. Open a mono sub '
          'through the filter you want to reach.',
    );
  }

  final int? imageId = _capturedImageIdForPath(
    ref.watch(recentSessionFramesProvider),
    path,
  );
  final SolvedWcs? wcs = imageId == null
      ? null
      : _solvedWcs(
          ref.watch(capturedImageWcsProvider(imageId)).valueOrNull,
          size,
        );
  final bool isStackReference = stackReference != null &&
      _normalisePath(stackReference) == _normalisePath(path);

  return DepthLockSelection(
    referencePath: path,
    capturedImageId: imageId,
    wcs: wcs,
    geometry: wcs == null ? null : depthLockReferenceFromSolvedWcs(wcs),
    imageSize: size,
    isLiveStackReference: isStackReference,
    advisory: wcs != null
        ? (isStackReference
            ? 'This is the sub the live stack is aligned to, so a region '
                'marked here is the one the stack is accumulating.'
            : null)
        : isStackReference
            // The exact frame the stack is registered to, and the exact remedy.
            ? 'The live stack\'s reference sub ${p.basename(path)} has no plate '
                'solve; solve it or open a solved sub. DepthLock will still use '
                'the WCS in the file\'s own header if it carries one.'
            : 'Skotiq has no plate solve on record for this frame. DepthLock '
                'will use the WCS in the file\'s own header if it has one; '
                'otherwise plate-solve the sub first. Saved goals are only drawn '
                'over a solved frame.',
  );
});

/// The `captured_images` row whose file is [path].
///
/// Mirrors the preview's own frame resolver: paths reach the two sides through
/// different code (one from the capture pipeline, one from the database), so
/// they are compared normalised, and a basename match is only accepted when it
/// is unambiguous.
int? _capturedImageIdForPath(List<CapturedImage> frames, String path) {
  final String wanted = _normalisePath(path);
  for (final frame in frames) {
    if (_normalisePath(frame.filePath) == wanted) {
      final parsed = int.tryParse(frame.id);
      if (parsed != null) return parsed;
    }
  }
  final String wantedName = _normalisePath(p.basename(path));
  final matches = frames
      .where(
        (frame) => _normalisePath(p.basename(frame.filePath)) == wantedName,
      )
      .toList(growable: false);
  if (matches.length == 1) return int.tryParse(matches.single.id);
  return null;
}

String _normalisePath(String value) => value
    .trim()
    .replaceAll('\\', '/')
    .replaceAll(RegExp(r'/+'), '/')
    .toLowerCase();

SolvedWcs? _solvedWcs(CapturedImageWcsData? data, Size size) {
  if (data == null || !data.isPlateSolved) return null;
  final ra = data.solvedRaHours;
  final dec = data.solvedDecDegrees;
  final rotation = data.solvedRotationDegrees;
  final scale = data.solvedPixelScaleArcsecPerPixel;
  if (ra == null || dec == null || rotation == null || scale == null) {
    return null;
  }
  final wcs = SolvedWcs(
    raHours: ra,
    decDegrees: dec,
    rotationDeg: rotation,
    pixelScaleArcsec: scale,
    imageWidth: size.width.round(),
    imageHeight: size.height.round(),
  );
  return wcs.isValid ? wcs : null;
}

/// A refusal the create path can explain to the operator in one sentence.
class DepthLockSelectionException implements Exception {
  const DepthLockSelectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// An aperture side that is legal for both the sampler and the grid.
///
/// The native limits pull in opposite directions: the sampler wants an
/// aperture of 4–64 native pixels, and the grid wants 16–256 whole apertures
/// inside the region. This picks a scale near a hundred apertures and then
/// pulls it inside whichever bound it broke, so the editor opens on something
/// the validator accepts instead of on an error the operator did not cause.
double depthLockProposedScaleArcsec({
  required double regionWidthArcsec,
  required double regionHeightArcsec,
  required double pixelScaleArcsec,
}) {
  final double lower = math.max(2.0, 4.0 * pixelScaleArcsec);
  final double upper = math.max(lower, 64.0 * pixelScaleArcsec);
  final double shortSide = math.min(regionWidthArcsec, regionHeightArcsec);
  double scale = shortSide <= 0 ? lower : shortSide / 10.0;
  scale = scale.clamp(lower, upper);

  int cells(double side) {
    final int columns = (regionWidthArcsec / side).floor();
    final int rows = (regionHeightArcsec / side).floor();
    return columns <= 0 || rows <= 0 ? 0 : columns * rows;
  }

  // Coarsen while the grid is too fine, then refine while it is too coarse.
  // Both loops are bounded by the sampler's own limits, so neither can run
  // away on a degenerate region.
  var guard = 0;
  while (cells(scale) > 256 && scale < upper && guard++ < 32) {
    scale = math.min(upper, scale * 1.25);
  }
  guard = 0;
  while (cells(scale) < 16 && scale > lower && guard++ < 32) {
    scale = math.max(lower, scale / 1.25);
  }
  return double.parse(scale.toStringAsFixed(2));
}

/// Assemble the definition a new goal opens its editor on.
///
/// The reference geometry comes from the file's own header when it carries an
/// undistorted TAN solution — that is the frame's own statement about where it
/// was pointing — and falls back to Skotiq's plate solve for the same
/// frame only when the header has none.
Future<DepthLockGoalDefinition> buildDepthLockGoalDefinition({
  required DepthLockBackend backend,
  required String referencePath,
  required Rect structure,
  required Rect background,
  required SolvedWcs? fallbackWcs,
  required String projectId,
  required String targetId,
  required String profileId,
  required String label,
  String? darkPath,
  String? flatPath,
  double temperatureToleranceC = 1.0,
  Size? drawnOnSize,
}) async {
  final DepthLockReferenceInfo info =
      await backend.inspectDepthLockReference(referencePath);
  // The rectangles are in the pixels of whatever was on screen. If that is not
  // the same grid as the reference frame — a stack that does not match the sub
  // it claims to be registered to — the region would land somewhere else
  // entirely, and no later check would notice.
  if (drawnOnSize != null &&
      (info.width != drawnOnSize.width.round() ||
          info.height != drawnOnSize.height.round())) {
    throw DepthLockSelectionException(
      'The image the region was drawn on is '
      '${drawnOnSize.width.round()} × ${drawnOnSize.height.round()}, but '
      '${p.basename(referencePath)} is ${info.width} × ${info.height}. They '
      'have to be the same grid for the region to mean anything.',
    );
  }
  if (!info.monochrome) {
    throw const DepthLockSelectionException(
      'DepthLock measures monochrome 16-bit data. This file is not a mono '
      'sub, so it cannot anchor a goal.',
    );
  }
  final ReferenceGeometry? geometry = info.geometry ??
      (fallbackWcs == null
          ? null
          : depthLockReferenceFromSolvedWcs(fallbackWcs));
  if (geometry == null) {
    throw DepthLockSelectionException(
      info.geometryIssue ??
          'This frame carries no usable astrometry, so the region cannot be '
              'anchored on the sky. Plate-solve the sub and try again.',
    );
  }
  if (info.acquisitionIssue != null || info.acquisition == null) {
    throw DepthLockSelectionException(
      info.acquisitionIssue ??
          'This frame\'s header does not say how it was acquired, so a goal '
              'cannot record the setup later frames must match.',
    );
  }

  final SkyRectangle region = await backend.depthLockSkyRectangle(
    reference: geometry,
    x0: structure.left,
    y0: structure.top,
    x1: structure.right,
    y1: structure.bottom,
  );
  final SkyRectangle backgroundSky = await backend.depthLockSkyRectangle(
    reference: geometry,
    x0: background.left,
    y0: background.top,
    x1: background.right,
    y1: background.bottom,
  );

  // A new goal opens on the Faint preset, which is what an operator who just
  // drew a box around something they can see is asking for. A small region
  // cannot hold sixteen whole apertures at that scale, so it falls back to the
  // finest scale the region and the sampler both allow rather than opening the
  // editor on a definition the validator refuses.
  final double presetScale = depthLockPresetScale(
    DepthLockPreset.faint,
    pixelScaleArcsec: geometry.pixelScaleArcsec,
  );
  final int presetCells = (region.widthArcsec / presetScale).floor() *
      (region.heightArcsec / presetScale).floor();
  final double scale = presetCells >= 16
      ? presetScale
      : depthLockProposedScaleArcsec(
          regionWidthArcsec: region.widthArcsec,
          regionHeightArcsec: region.heightArcsec,
          pixelScaleArcsec: geometry.pixelScaleArcsec,
        );

  return DepthLockGoalDefinition(
    label: label,
    projectId: projectId,
    targetId: targetId,
    profileId: profileId,
    filterName: info.acquisition!.filter,
    filterIndex: null,
    referencePath: referencePath,
    reference: geometry,
    acquisition: info.acquisition!,
    temperatureToleranceC: temperatureToleranceC,
    darkPath: darkPath ?? '',
    flatPath: flatPath ?? '',
    measurement: DepthLockMeasurement(
      region: region,
      background: backgroundSky,
      scaleArcsec: scale,
      threshold: DepthLockPreset.faint.threshold,
      minCoverage: kDepthLockDefaultCoverage,
      systematicFloorAdu: kDepthLockSeedFloorAdu,
      systematicFloorSource: kDepthLockSeedFloorSource,
    ),
    enabled: true,
    // Automation is off until the operator turns it on, deliberately: a goal
    // that could end a filter early the moment it is created is not something
    // to opt out of after the fact.
    automaticCompletion: false,
  );
}

/// A goal re-anchored on the frame its region was just re-drawn on.
///
/// The rectangles are stored on the sky, so moving a goal's region to a new
/// reference frame is legitimate — but the frozen geometry and the path it
/// came from have to describe the SAME frame, or the goal carries a stale
/// inherited WCS, which is the first of the design's named hazards. So the
/// reference, its path and the acquisition all come from [fresh] together,
/// while everything the operator chose — the label, the filter, the depth, the
/// masters, the preferences — stays as it was.
///
/// The caller is responsible for having said that this is a revision and that
/// the evidence starts over.
DepthLockGoalDefinition depthLockDefinitionWithNewRegion({
  required DepthLockGoalDefinition previous,
  required DepthLockGoalDefinition fresh,
}) =>
    DepthLockGoalDefinition(
      label: previous.label,
      projectId: previous.projectId,
      targetId: previous.targetId,
      profileId: previous.profileId,
      filterName: previous.filterName,
      filterIndex: previous.filterIndex,
      referencePath: fresh.referencePath,
      reference: fresh.reference,
      acquisition: fresh.acquisition,
      temperatureToleranceC: previous.temperatureToleranceC,
      darkPath: previous.darkPath,
      flatPath: previous.flatPath,
      measurement: previous.measurement.copyWith(
        region: fresh.measurement.region,
        background: fresh.measurement.background,
      ),
      enabled: previous.enabled,
      automaticCompletion: previous.automaticCompletion,
    );

/// Which canvas the region tool is working on.
///
/// Two canvases can host the tool — the live view's sub and the live stack —
/// and a region belongs to exactly one of them. The Imaging screen sets this
/// from the tab it is showing; everything that asks "can a region be marked
/// right now" reads [depthLockActiveSelectionProvider] rather than picking a
/// canvas itself.
enum DepthLockCanvas { liveView, liveStack }

final depthLockCanvasProvider = StateProvider<DepthLockCanvas>(
  (ref) => DepthLockCanvas.liveView,
);

/// The running stack's reference sub, as the native inspector describes it.
///
/// The stack has no header of its own, so everything a goal needs — the
/// dimensions to check against, the acquisition, and the header TAN solution
/// when there is one — comes from the sub the stack is registered to.
final depthLockStackReferenceProvider =
    FutureProvider<DepthLockReferenceInfo?>((ref) async {
  // Selected down to the two fields that matter, NOT the whole stacking
  // state: that state carries the preview buffer and changes on every
  // stacked frame, and re-reading the reference file from disk once a
  // frame would be a header read per exposure for an answer that cannot
  // change while the stack runs.
  final path = ref.watch(
    liveStackingProvider.select(
      (state) => state.status == LiveStackingStatus.running
          ? state.referenceImagePath?.trim()
          : null,
    ),
  );
  if (path == null || path.isEmpty) return null;
  return ref.watch(depthLockBackendProvider).inspectDepthLockReference(
        path,
      );
});

/// What the live stack canvas can offer DepthLock.
///
/// The stacker warps every frame into the reference sub's pixel grid, so a
/// rectangle drawn on the stacked image IS a rectangle in the reference sub's
/// pixels — which is what makes marking here legitimate at all. That identity
/// is only true while the two are the same size, so a disagreement is a hard
/// block rather than a warning.
final depthLockStackSelectionProvider = Provider<DepthLockSelection>((ref) {
  final stack = ref.watch(liveStackingProvider);
  if (stack.status != LiveStackingStatus.running) {
    return const DepthLockSelection(
      blocker: 'The live stacker is not running. Start a stack from a sub and '
          'the region can be marked on the stacked image.',
    );
  }
  final String? referencePath = stack.referenceImagePath?.trim();
  if (referencePath == null || referencePath.isEmpty) {
    return const DepthLockSelection(
      blocker: 'This stack was not started from a file, so it has no '
          'reference sub to anchor a region to.',
    );
  }
  if (stack.previewData == null ||
      stack.previewWidth <= 0 ||
      stack.previewHeight <= 0) {
    return const DepthLockSelection(
      blocker: 'The stack has no image yet. Once a frame has been stacked the '
          'region can be marked on it.',
    );
  }

  final Size stackSize = Size(
    stack.previewWidth.toDouble(),
    stack.previewHeight.toDouble(),
  );
  final AsyncValue<DepthLockReferenceInfo?> info = ref.watch(
    depthLockStackReferenceProvider,
  );
  final DepthLockReferenceInfo? reference = info.valueOrNull;
  if (info.hasError) {
    return DepthLockSelection(
      imageSize: stackSize,
      blocker: depthLockErrorMessage(info.error!),
    );
  }
  if (reference == null) {
    return DepthLockSelection(
      imageSize: stackSize,
      blocker: 'Reading the stack\'s reference sub '
          '${p.basename(referencePath)}…',
    );
  }
  if (!reference.monochrome) {
    return DepthLockSelection(
      imageSize: stackSize,
      blocker: 'DepthLock measures monochrome, linear data. The stack\'s '
          'reference sub ${p.basename(referencePath)} is not a mono sub.',
    );
  }
  if (reference.width != stack.previewWidth ||
      reference.height != stack.previewHeight) {
    return DepthLockSelection(
      imageSize: stackSize,
      blocker:
          'The stack is ${stack.previewWidth} × ${stack.previewHeight} but its '
          'reference sub ${p.basename(referencePath)} is ${reference.width} × '
          '${reference.height}. A region drawn here would not land on the '
          'reference frame, so DepthLock cannot anchor it.',
    );
  }

  // Saved goals are drawn through Skotiq's own plate solve for the
  // reference sub when it has one, else through the sub's header solution —
  // both are full TAN geometries, and the stack shares the sub's pixel grid.
  final int? imageId = _capturedImageIdForPath(
    ref.watch(recentSessionFramesProvider),
    referencePath,
  );
  final SolvedWcs? wcs = imageId == null
      ? null
      : _solvedWcs(
          ref.watch(capturedImageWcsProvider(imageId)).valueOrNull,
          stackSize,
        );
  final ReferenceGeometry? geometry =
      wcs != null ? depthLockReferenceFromSolvedWcs(wcs) : reference.geometry;

  return DepthLockSelection(
    referencePath: referencePath,
    capturedImageId: imageId,
    wcs: wcs,
    geometry: geometry,
    imageSize: stackSize,
    isLiveStackReference: true,
    advisory: geometry != null
        ? 'Marking on the stacked image. The goal is anchored to '
            '${p.basename(referencePath)}, the sub the stack is aligned to'
            '${wcs == null ? ', through its own header solution' : ''}.'
        : 'Neither Skotiq nor the file\'s header has a plate solve for '
            'the stack\'s reference sub ${p.basename(referencePath)}, so '
            'a region cannot be anchored yet. Solve that sub.',
  );
});

/// The selection for the canvas the operator is actually looking at.
final depthLockActiveSelectionProvider = Provider<DepthLockSelection>((ref) {
  return switch (ref.watch(depthLockCanvasProvider)) {
    DepthLockCanvas.liveView => ref.watch(depthLockSelectionProvider),
    DepthLockCanvas.liveStack => ref.watch(depthLockStackSelectionProvider),
  };
});
