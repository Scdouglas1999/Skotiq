// The frame stage: the latest frame, front and center, with what the rig is
// doing written over it.
//
// The frame is Imaging's own current frame drawn by [ImageDisplayWidget], and
// the view buttons drive the same shared state Imaging's toolbar does
// (`imagingViewerStateProvider`, the auto-stretch setting, the star overlay
// and the catalog overlay), so a stretch chosen here holds on Imaging too.
// Pills: the frame on screen (top left), what is happening now (top right),
// a thin exposure bar along the top edge.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../utils/preview_transform.dart';
import '../../../widgets/catalog_overlay_widget.dart';
import '../../../widgets/frame_exclusion_badge.dart';
import '../../../widgets/frame_thumbnail_loader.dart';
import '../../imaging/widgets/image_display.dart';
import '../../imaging/widgets/overlay_painters.dart';
import '../../imaging/widgets/preview_display_scale.dart';
import '../actions/night_action_controller.dart';
import '../data/plan/night_header_provider.dart';
import '../data/plan/night_run_phase_provider.dart';
import '../data/plan/night_target_provider.dart';
import '../data/session/camera_exposure_provider.dart';
import '../data/session/session_frames_provider.dart';
import '../night_control_contracts.dart';
import 'center_format.dart';

part 'frame_stage_overlays.dart';

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

/// The strip frame the operator tapped; null follows the newest frame.
final nightStageSelectionProvider = StateProvider<int?>((ref) => null);

/// The live frame: Imaging's current frame, which the run, a snapshot and
/// autofocus all feed.
final nightStageImageProvider = Provider<CapturedImageData?>(
  (ref) => ref.watch(currentImageProvider),
);

/// Whether auto-stretch is on for the frame on screen.
final nightStageStretchProvider = Provider<bool>(
  (ref) => ref.watch(autoStretchSettingsProvider).enabled,
);

/// The exposure in flight.
///
/// A manual capture reports its own elapsed time ([elapsed]). A run's
/// exposures run in the native sequencer, which only says when one starts,
/// so for those [startedAt] is when the camera began exposing and the stage
/// counts from it.
@immutable
class NightExposureVm {
  const NightExposureVm({this.elapsed, this.startedAt, this.total});

  /// Seconds exposed, as the capture reported it.
  final double? elapsed;

  /// When the exposure started, a true instant (UTC).
  final DateTime? startedAt;

  /// The exposure length; null when nothing says it.
  final double? total;

  /// Seconds exposed at [nowUtc]; null when neither source says.
  double? elapsedAt(DateTime nowUtc) {
    final reported = elapsed;
    if (reported != null) return reported;
    final start = startedAt;
    if (start == null) return null;
    final seconds = nowUtc.difference(start).inMilliseconds / 1000;
    final length = total;
    return length == null ? seconds : seconds.clamp(0.0, length);
  }

  /// 0 to 1 at [nowUtc]; null without a length.
  double? fractionAt(DateTime nowUtc) {
    final length = total;
    final done = elapsedAt(nowUtc);
    if (length == null || length <= 0 || done == null) return null;
    return (done / length).clamp(0.0, 1.0);
  }

  @override
  bool operator ==(Object other) =>
      other is NightExposureVm &&
      other.elapsed == elapsed &&
      other.startedAt == startedAt &&
      other.total == total;

  @override
  int get hashCode => Object.hash(elapsed, startedAt, total);
}

/// When the camera last started exposing, a true instant.
final _exposureStartProvider =
    NotifierProvider<_ExposureStartRecorder, DateTime?>(
  _ExposureStartRecorder.new,
);

class _ExposureStartRecorder extends Notifier<DateTime?> {
  @override
  DateTime? build() {
    ref.listen<bool>(
      cameraStateProvider.select((camera) => camera.isExposing),
      (previous, exposing) {
        if (exposing && previous != true) {
          state = ref.read(clockProvider).nowUtc();
        } else if (!exposing) {
          state = null;
        }
      },
    );
    return null;
  }
}

/// The camera's exposure in flight; null when it is idle.
///
/// The camera's own events say when every exposure starts, how long it is
/// and when it ends, a run's frames included. The imaging service's progress
/// is the fallback for a capture whose start this app did not see.
final nightStageExposureProvider = Provider<NightExposureVm?>((ref) {
  final camera = ref.watch(nightCameraExposureProvider);
  if (camera != null) {
    return NightExposureVm(
      startedAt: camera.endsAt.subtract(
        Duration(milliseconds: (camera.total * 1000).round()),
      ),
      total: camera.total,
    );
  }
  // Watched first so the recorder is alive before the next exposure starts;
  // one that started before Tonight opened has no known start.
  final startedAt = ref.watch(_exposureStartProvider);
  final exposing = ref.watch(
    cameraStateProvider.select((camera) => camera.isExposing),
  );
  if (!exposing) return null;
  final phase = ref.watch(nightRunPhaseProvider);
  // `exposureProgressProvider` follows only captures made through the
  // imaging service (snapshot, loop, autofocus frames) and the remote
  // mirror; the run's own frames never reach it, so during a run the
  // countdown comes from the run's start time instead.
  if (phase != NightRunPhase.running) {
    final progress = ref.watch(exposureProgressProvider);
    final total = progress.elapsed + progress.remaining;
    if (!progress.isDownloading && total > 0) {
      return NightExposureVm(elapsed: progress.elapsed, total: total);
    }
  }
  return NightExposureVm(
    startedAt: startedAt,
    total: ref.watch(nightHeaderProvider.select((h) => h.currentExposureSecs)),
  );
});

/// A running autofocus, for "Autofocus · point 6 of 9".
@immutable
class NightAutofocusVm {
  const NightAutofocusVm({this.point, this.points, this.hfr});

  /// 1-based; null before the first point.
  final int? point;
  final int? points;
  final double? hfr;

  @override
  bool operator ==(Object other) =>
      other is NightAutofocusVm &&
      other.point == point &&
      other.points == points &&
      other.hfr == hfr;

  @override
  int get hashCode => Object.hash(point, points, hfr);
}

/// The autofocus run in progress; null when none runs.
final nightStageAutofocusProvider = Provider<NightAutofocusVm?>((ref) {
  final af = ref.watch(autofocusOverlayProvider);
  if (!af.isRunning) return null;
  // The overlay starts its counters at 0 before the first point lands.
  return NightAutofocusVm(
    point: af.currentPoint > 0 ? af.currentPoint : null,
    points: af.totalPoints > 0 ? af.totalPoints : null,
    hfr: af.currentHfr > 0 ? af.currentHfr : null,
  );
});

/// A plate solve of the frame on screen.
@immutable
class NightStageSolveVm {
  const NightStageSolveVm({
    required this.frameCapturedAt,
    required this.raDegrees,
    required this.decDegrees,
    required this.rotationDeg,
    required this.pixelScaleArcsec,
    this.offTargetArcmin,
    this.cd,
    this.sip,
  });

  /// [CapturedImageData.capturedAt] of the frame that was solved.
  final DateTime frameCapturedAt;
  final double raDegrees;
  final double decDegrees;
  final double rotationDeg;
  final double pixelScaleArcsec;

  /// Distance from the plan's target; null without a target.
  final double? offTargetArcmin;

  /// The solver's CD matrix and SIP block, which carry the frame's parity
  /// and distortion; null when the solve reported none.
  final FrameSolveCd? cd;
  final String? sip;

  @override
  bool operator ==(Object other) =>
      other is NightStageSolveVm &&
      other.frameCapturedAt == frameCapturedAt &&
      other.raDegrees == raDegrees &&
      other.decDegrees == decDegrees &&
      other.rotationDeg == rotationDeg &&
      other.pixelScaleArcsec == pixelScaleArcsec &&
      other.offTargetArcmin == offTargetArcmin &&
      other.cd == cd &&
      other.sip == sip;

  @override
  int get hashCode => Object.hash(frameCapturedAt, raDegrees, decDegrees,
      rotationDeg, pixelScaleArcsec, offTargetArcmin, cd, sip);
}

/// Pairs each successful solve with the frame that was on screen when it
/// landed. The solver's own state names a file path, and snapshots reuse one
/// scratch path, so the path alone cannot tell this frame from the last.
final _solvedFrameProvider =
    NotifierProvider<_SolvedFrameRecorder, (PlateSolveResult, DateTime)?>(
  _SolvedFrameRecorder.new,
);

class _SolvedFrameRecorder extends Notifier<(PlateSolveResult, DateTime)?> {
  @override
  (PlateSolveResult, DateTime)? build() {
    ref.listen<PlateSolveState>(plateSolveStateProvider, (previous, next) {
      final result = next.lastResult;
      if (result == null || !result.success) return;
      if (identical(result, previous?.lastResult)) return;
      final frame = ref.read(currentImageProvider);
      state = frame == null ? null : (result, frame.capturedAt);
    });
    return null;
  }
}

/// The solve of the frame on screen: its background solve, else an
/// operator's solve made of it while it was on screen.
final nightStageSolveProvider = Provider<NightStageSolveVm?>((ref) {
  final image = ref.watch(nightStageImageProvider);
  if (image == null) return null;
  final target = ref.watch(nightTargetProvider);
  NightStageSolveVm solveVm({
    required double ra,
    required double dec,
    required double rotation,
    required double scale,
    FrameSolveCd? cd,
    String? sip,
  }) =>
      NightStageSolveVm(
        frameCapturedAt: image.capturedAt,
        raDegrees: ra,
        decDegrees: dec,
        rotationDeg: rotation,
        pixelScaleArcsec: scale,
        cd: cd,
        sip: sip,
        offTargetArcmin: target == null
            ? null
            : nightSeparationDegrees(
                  ra,
                  dec,
                  target.raHours * 15,
                  target.decDegrees,
                ) *
                60,
      );
  final auto = ref.watch(currentFrameSolveProvider);
  if (auto != null &&
      auto.isSolved &&
      auto.frameCapturedAt == image.capturedAt) {
    return solveVm(
      ra: auto.raDegrees!,
      dec: auto.decDegrees!,
      rotation: auto.rotationDeg!,
      scale: auto.pixelScaleArcsec!,
      cd: auto.cd,
      sip: auto.sip,
    );
  }
  final solved = ref.watch(_solvedFrameProvider);
  if (solved == null) return null;
  final (result, capturedAt) = solved;
  if (capturedAt != image.capturedAt) return null;
  return solveVm(
    ra: result.ra,
    dec: result.dec,
    rotation: result.rotation,
    scale: result.pixelScale,
    cd: frameSolveCdOf(result),
    sip: encodeSolvedSip(
      aOrder: result.sipAOrder,
      bOrder: result.sipBOrder,
      aCoeffs: result.sipACoeffs.toList(),
      bCoeffs: result.sipBCoeffs.toList(),
      apOrder: result.sipApOrder,
      bpOrder: result.sipBpOrder,
      apCoeffs: result.sipApCoeffs.toList(),
      bpCoeffs: result.sipBpCoeffs.toList(),
    ),
  );
});

/// Angular distance in degrees between two J2000 positions in degrees.
double nightSeparationDegrees(
  double ra1Deg,
  double dec1Deg,
  double ra2Deg,
  double dec2Deg,
) {
  const toRad = math.pi / 180;
  final dRa = (ra2Deg - ra1Deg) * toRad;
  final dDec = (dec2Deg - dec1Deg) * toRad;
  final a = math.pow(math.sin(dDec / 2), 2) +
      math.cos(dec1Deg * toRad) *
          math.cos(dec2Deg * toRad) *
          math.pow(math.sin(dRa / 2), 2);
  return 2 * math.asin(math.min(1, math.sqrt(a))) / toRad;
}

/// Snapshots and loop frames that are not kept land on one reused scratch
/// file per camera (`liveview_<camera>.fits`, see ImagingService); a frame
/// there is shown but never saved.
bool nightIsScratchFrame(String? filePath) =>
    filePath != null && p.basename(filePath).startsWith('liveview_');

/// The run phases in which nothing has been captured for tonight yet.
bool nightIsBeforeRun(NightRunPhase phase) =>
    phase == NightRunPhase.notSetUp ||
    phase == NightRunPhase.ready ||
    phase == NightRunPhase.armed;

// ---------------------------------------------------------------------------
// The stage
// ---------------------------------------------------------------------------

/// The latest frame with its pills, view buttons and exposure bar.
class FrameStage extends ConsumerWidget {
  const FrameStage({super.key});

  /// The thin exposure bar along the top edge.
  static const double progressBarHeight = 3;

  static const double _inset = 10;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    // Keep the solve recorder alive, so a solve that lands before its pill
    // is on screen is still paired with its frame.
    ref.listen(_solvedFrameProvider, (_, __) {});
    final image = ref.watch(nightStageImageProvider);
    final frames = ref.watch(nightSessionFramesProvider);
    final selectedId = ref.watch(nightStageSelectionProvider);
    StripFrameVm? selected;
    for (final frame in frames) {
      if (frame.id == selectedId) selected = frame;
    }
    final canvas =
        colors.isRedNight ? colors.background : SkotiqColors.dark.background;

    return ColoredBox(
      color: canvas,
      child: SkotiqImageSurface(
        child: ClipRect(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final viewport =
                  Size(constraints.maxWidth, constraints.maxHeight);
              return Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: selected != null
                        ? _SelectedFramePreview(frame: selected)
                        : image != null
                            ? _LiveFrame(image: image, viewport: viewport)
                            : const _EmptyStage(),
                  ),
                  Positioned.fill(
                    child: _ExposureTicker(
                      builder: (context, nowUtc) => Stack(
                        children: <Widget>[
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 0,
                            child: _ProgressBar(nowUtc: nowUtc),
                          ),
                          Positioned(
                            left: _inset,
                            right: _inset,
                            top: _inset,
                            child: _TopPills(
                              image: image,
                              selected: selected,
                              nowUtc: nowUtc,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (selected != null)
                    const Positioned(
                      left: _inset,
                      bottom: _inset,
                      child: _BackToLatest(),
                    )
                  else if (image != null)
                    Positioned(
                      right: _inset,
                      bottom: _inset,
                      left: _inset,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: <Widget>[
                          const Flexible(child: _OverlayStatus()),
                          const SizedBox(width: SkotiqTokens.spaceSm),
                          Flexible(
                            flex: 2,
                            child: Align(
                              alignment: Alignment.bottomRight,
                              child: _ViewButtons(
                                image: image,
                                viewport: viewport,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The current frame with the star and catalog overlays.
class _LiveFrame extends ConsumerWidget {
  const _LiveFrame({required this.image, required this.viewport});

  final CapturedImageData image;
  final Size viewport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final viewer = ref.watch(imagingViewerStateProvider);
    final showStars = viewer.showStarOverlay;
    final stars =
        showStars ? ref.watch(currentFrameStarsProvider).valueOrNull : null;
    final imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final fitScale =
        previewFitScale(viewportSize: viewport, imageSize: imageSize);
    final displayScale = fitScale * viewer.zoomLevel;
    final imageOffset = computeImageOffset(
      viewportSize: viewport,
      imageSize: imageSize,
      zoomLevel: displayScale,
      panOffset: viewer.panOffset,
    );
    final zoomed = viewer.zoomLevel != 1.0;
    // Decode only what the stage can show while fitted; 1:1 needs every pixel.
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final targetWidth =
        zoomed ? null : math.max(1, (viewport.width * dpr).round());

    return Semantics(
      image: true,
      label: _frameSemantics(context, ref, image),
      child: GestureDetector(
        onPanUpdate: zoomed
            ? (details) =>
                ref.read(imagingViewerStateProvider.notifier).pan(details.delta)
            : null,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ExcludeSemantics(
              child: ImageDisplayWidget(
                imageData: image,
                zoomLevel: viewer.zoomLevel,
                panOffset: viewer.panOffset,
                targetWidth: targetWidth,
              ),
            ),
            if (stars != null && stars.stars.isNotEmpty)
              IgnorePointer(
                child: CustomPaint(
                  painter: StarOverlayPainter(
                    stars: stars.stars,
                    color: colors.accent.withValues(alpha: 0.8),
                    zoomLevel: displayScale,
                    imageOffset: imageOffset,
                  ),
                ),
              ),
            if (ref.watch(catalogOverlayEnabledProvider))
              CatalogOverlayWidget(
                wcs: _wcsFor(ref, image),
                zoomLevel: displayScale,
                imageOffset: imageOffset,
                imageSize: imageSize,
                frameSolve: ref.watch(currentFrameSolveProvider),
              ),
          ],
        ),
      ),
    );
  }

  /// The frame's solution: its saved row's WCS, else a solve made of it
  /// while it was on screen.
  SolvedWcs? _wcsFor(WidgetRef ref, CapturedImageData image) {
    final id = _stripFrameFor(ref.watch(nightSessionFramesProvider), image)?.id;
    if (id != null) {
      final wcs = ref.watch(capturedImageWcsProvider(id)).valueOrNull;
      if (wcs != null && wcs.isPlateSolved) {
        final stored = solvedWcsFromStored(
          raHours: wcs.solvedRaHours,
          decDegrees: wcs.solvedDecDegrees,
          rotationDeg: wcs.solvedRotationDegrees,
          pixelScaleArcsec: wcs.solvedPixelScaleArcsecPerPixel,
          imageWidth: image.width,
          imageHeight: image.height,
          cd1_1: wcs.cd1_1,
          cd1_2: wcs.cd1_2,
          cd2_1: wcs.cd2_1,
          cd2_2: wcs.cd2_2,
          sip: wcs.sip,
        );
        if (stored != null) return stored;
      }
    }
    final solve = ref.watch(nightStageSolveProvider);
    if (solve == null) return null;
    return solvedWcsFromStored(
      raHours: solve.raDegrees / 15,
      decDegrees: solve.decDegrees,
      rotationDeg: solve.rotationDeg,
      pixelScaleArcsec: solve.pixelScaleArcsec,
      imageWidth: image.width,
      imageHeight: image.height,
      cd1_1: solve.cd?.cd1_1,
      cd1_2: solve.cd?.cd1_2,
      cd2_1: solve.cd?.cd2_1,
      cd2_2: solve.cd?.cd2_2,
      sip: solve.sip,
    );
  }
}

/// The session frame saved at [image]'s path, if any.
StripFrameVm? _stripFrameFor(
    List<StripFrameVm> frames, CapturedImageData? image) {
  final path = image?.filePath;
  if (path == null || path.isEmpty) return null;
  for (var i = frames.length - 1; i >= 0; i--) {
    if (frames[i].filePath == path) return frames[i];
  }
  return null;
}

String _frameSemantics(
  BuildContext context,
  WidgetRef ref,
  CapturedImageData image,
) {
  final l10n = context.l10n;
  final pill = _framePill(context, ref, image);
  return l10n.text(
    'nightCtrFrameSemantics',
    params: <String, String>{
      'frame': <String>[
        pill.title,
        if (pill.time != null) pill.time!,
        if (pill.status != null) pill.status!,
      ].join(', '),
    },
  );
}

/// A strip frame shown on the stage: its thumbnail, scaled to fit.
class _SelectedFramePreview extends ConsumerStatefulWidget {
  const _SelectedFramePreview({required this.frame});

  final StripFrameVm frame;

  @override
  ConsumerState<_SelectedFramePreview> createState() =>
      _SelectedFramePreviewState();
}

class _SelectedFramePreviewState extends ConsumerState<_SelectedFramePreview> {
  Future<Uint8List?>? _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  @override
  void didUpdateWidget(covariant _SelectedFramePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frame.id != widget.frame.id) _bytes = _load();
  }

  // The sidecar thumbnail (about 512 px), never a full-resolution decode.
  Future<Uint8List?> _load() =>
      fetchFrameThumbnailBytes(ref, widget.frame.id, source: 'NightStage');

  @override
  Widget build(BuildContext context) {
    final frame = widget.frame;
    final l10n = context.l10n;
    return Semantics(
      image: true,
      label: l10n.text(
        'nightCtrPreviewSemantics',
        params: <String, String>{
          'frame': _stripTitle(frame) ?? l10n.text('nightCtrFrame'),
        },
      ),
      child: ExcludeSemantics(
        child: FrameThumbnail(
          bytesFuture: _bytes,
          fallbackFilePath: frame.filePath ?? nightNoLocalFile,
          colors: context.skotiqColors,
          iconSize: 28,
          fit: BoxFit.contain,
        ),
      ),
    );
  }
}

String? _stripTitle(StripFrameVm frame) {
  final what = nightFilterExposure(frame.filter, frame.exposureSecs);
  final number = frame.frameNumber;
  if (number == null) return what;
  return what == null ? '#$number' : '#$number · $what';
}

/// No frame yet: before the run, or a run whose first frame is still out.
class _EmptyStage extends ConsumerWidget {
  const _EmptyStage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final before = nightIsBeforeRun(ref.watch(nightRunPhaseProvider));
    // While an exposure is out the pills own the canvas; the prompt would
    // tell the operator to take a frame that is already being taken.
    if (ref.watch(nightStageExposureProvider) != null ||
        ref.watch(nightStageAutofocusProvider) != null) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        primary: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: EmptyState(
              icon: SkotiqIcons.imageOff,
              title: l10n.text(
                before ? 'nightCtrNothingYet' : 'nightCtrWaitingFirst',
              ),
              body: l10n.text(
                before ? 'nightCtrNothingYetBody' : 'nightCtrWaitingFirstBody',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rebuilds [builder] every second while a run's exposure counts up from
/// its start; otherwise only when the providers change.
class _ExposureTicker extends ConsumerStatefulWidget {
  const _ExposureTicker({required this.builder});

  final Widget Function(BuildContext context, DateTime nowUtc) builder;

  @override
  ConsumerState<_ExposureTicker> createState() => _ExposureTickerState();
}

class _ExposureTickerState extends ConsumerState<_ExposureTicker> {
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final counting = ref.watch(
      nightStageExposureProvider.select((e) => e?.startedAt != null),
    );
    if (counting && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!counting && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
    return widget.builder(context, ref.read(clockProvider).nowUtc());
  }
}

/// The thin bar along the stage's top: the exposure, or the autofocus run.
class _ProgressBar extends ConsumerWidget {
  const _ProgressBar({required this.nowUtc});

  final DateTime nowUtc;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final af = ref.watch(nightStageAutofocusProvider);
    final exposure = ref.watch(nightStageExposureProvider);
    double? fraction;
    final point = af?.point;
    final points = af?.points;
    if (point != null && points != null) {
      fraction = (point / points).clamp(0.0, 1.0);
    } else if (af == null && exposure != null) {
      fraction = exposure.fractionAt(nowUtc);
    }
    if (fraction == null) return const SizedBox.shrink();
    return ExcludeSemantics(
      child: SizedBox(
        height: FrameStage.progressBarHeight,
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: fraction,
          child: ColoredBox(color: context.skotiqColors.primary),
        ),
      ),
    );
  }
}
