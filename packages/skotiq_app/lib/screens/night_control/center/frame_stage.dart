// The frame stage: the latest frame, front and center, with what the rig is
// doing written over it.
//
// The frame is Imaging's own current frame, or a frame picked in the strip at
// full resolution from its own file; both are drawn by [FrameCanvas]. The view
// buttons drive the same shared state Imaging's toolbar does
// (`imagingViewerStateProvider`, the auto-stretch setting, the star overlay
// and the catalog overlay), so a stretch chosen here holds on Imaging too.
// Pills: the frame on screen (top left), what is happening now (top right),
// a thin exposure bar along the top edge.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../widgets/frame_exclusion_badge.dart';
import '../../../widgets/frame_purpose_label.dart';
import '../../../widgets/image_preview/frame_canvas.dart';
import '../../../widgets/image_preview/frame_overlay_controls.dart';
import '../../../widgets/image_preview/preview_display_scale.dart';
import '../../../widgets/saved_frame/saved_frame_view.dart';
import '../actions/night_action_controller.dart';
import '../data/plan/night_header_provider.dart';
import '../data/plan/night_run_phase_provider.dart';
import '../data/plan/night_target_provider.dart';
import '../data/session/camera_exposure_provider.dart';
import '../data/session/session_frames_provider.dart';
import '../night_control_contracts.dart';
import 'center_format.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

part 'frame_stage_overlays.dart';

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
  int get hashCode => Object.hash(
        frameCapturedAt,
        raDegrees,
        decDegrees,
        rotationDeg,
        pixelScaleArcsec,
        offTargetArcmin,
        cd,
        sip,
      );
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
            : AstronomyCalculations.angularSeparation(
                  ra1Deg: ra,
                  dec1Deg: dec,
                  ra2Deg: target.raHours * 15,
                  dec2Deg: target.decDegrees,
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
    cd: result.cdMatrix,
    sip: encodeSolvedSip(result.sipTerms),
  );
});

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

/// The latest frame with its pills, view buttons and exposure bar.
class FrameStage extends ConsumerWidget {
  const FrameStage({super.key});

  /// The thin exposure bar along the top edge.
  static const double progressBarHeight = 3;

  static const double _inset = 10;

  /// Below this stage width the star status gets its own line.
  static const double _stackStatusBelow = 560;

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
                        ? _SavedStageFrame(frame: selected, viewport: viewport)
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
                  if (selected != null || image != null)
                    Positioned(
                      right: _inset,
                      bottom: _inset,
                      left: _inset,
                      child: _StageControls(
                        live: image,
                        selected: selected,
                        viewport: viewport,
                        stacked: viewport.width < _stackStatusBelow,
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
    final viewer = ref.watch(imagingViewerStateProvider);
    final showCatalog = ref.watch(catalogOverlayEnabledProvider);
    return FrameCanvas(
      image: image,
      viewport: viewport,
      zoomLevel: viewer.zoomLevel,
      panOffset: viewer.panOffset,
      onPan: ref.read(imagingViewerStateProvider.notifier).pan,
      semanticsLabel: _frameSemantics(context, ref, image),
      // Never the previous frame's stars while this frame is being detected.
      stars: viewer.showStarOverlay
          ? ref
              .watch(currentFrameStarsProvider)
              .unwrapPrevious()
              .valueOrNull
              ?.stars
          : null,
      showCatalog: showCatalog,
      wcs: showCatalog ? _wcsFor(ref, image) : null,
      frameSolve: ref.watch(currentFrameSolveProvider),
    );
  }

  /// The frame's solution: its saved row's WCS, else a solve made of it
  /// while it was on screen.
  SolvedWcs? _wcsFor(WidgetRef ref, CapturedImageData image) {
    final id = _stripFrameFor(ref.watch(nightSessionFramesProvider), image)?.id;
    if (id != null) {
      final wcs = ref.watch(capturedImageWcsProvider(id)).valueOrNull;
      if (wcs != null && wcs.isPlateSolved) {
        final stored = wcs.solvedWcs(width: image.width, height: image.height);
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
    if ((frames[i].hostPath ?? frames[i].filePath) == path) return frames[i];
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

/// The saved frame of [frame], for the full-resolution load.
SavedFrameRef _savedFrameRef(StripFrameVm frame) => SavedFrameRef(
      imageId: frame.id,
      hostPath: frame.hostPath ?? '',
      capturedAt: frame.capturedAt,
    );

/// A strip frame on the stage at full resolution, following the stage's zoom,
/// pan and overlays.
class _SavedStageFrame extends ConsumerWidget {
  const _SavedStageFrame({required this.frame, required this.viewport});

  final StripFrameVm frame;
  final Size viewport;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewer = ref.watch(imagingViewerStateProvider);
    return SavedFrameView(
      frame: _savedFrameRef(frame),
      viewport: viewport,
      zoomLevel: viewer.zoomLevel,
      panOffset: viewer.panOffset,
      onPan: ref.read(imagingViewerStateProvider.notifier).pan,
      showStars: viewer.showStarOverlay,
      showCatalog: ref.watch(catalogOverlayEnabledProvider),
      semanticsLabel: context.l10n.text(
        'nightCtrPreviewSemantics',
        params: <String, String>{
          'frame': _stripTitle(frame) ?? context.l10n.text('nightCtrFrame'),
        },
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
    final phase = ref.watch(nightRunPhaseProvider);
    final before = nightIsBeforeRun(phase);
    // A finished run that took no frame is not waiting for one.
    final endedEmpty = phase == NightRunPhase.finished;
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
                endedEmpty
                    ? 'nightCtrEndedNoFrame'
                    : before
                        ? 'nightCtrNothingYet'
                        : 'nightCtrWaitingFirst',
              ),
              body: l10n.text(
                endedEmpty
                    ? 'nightCtrEndedNoFrameBody'
                    : before
                        ? 'nightCtrNothingYetBody'
                        : 'nightCtrWaitingFirstBody',
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
