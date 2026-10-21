// What the Darkroom pass view draws: the pass as a timeline of stages per
// filter lane, every sub's measurements, the image at the depth reached so
// far, and the channel fits of the color stage.
//
// A [PassTimeline] holds everything a pass has reported with the offset from
// the pass start at which it was reported; [PassTimeline.at] answers what the
// screen shows at one moment. A value is visible only once the stage that
// measures it has finished for that sub, so a moment never shows a number the
// pipeline had not produced yet.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// The stages of a pass, in the order they run.
enum PassStage {
  calibrate,
  register,
  normalize,
  integrate,
  write,
  align,
  combine,
  draft;

  String get label => switch (this) {
        PassStage.calibrate => 'Calibrate',
        PassStage.register => 'Register',
        PassStage.normalize => 'Normalize',
        PassStage.integrate => 'Integrate',
        PassStage.write => 'Write',
        PassStage.align => 'Align channels',
        PassStage.combine => 'Combine color',
        PassStage.draft => 'Drafts',
      };

  /// The present-tense verb for the status line.
  String get verb => switch (this) {
        PassStage.calibrate => 'Calibrating',
        PassStage.register => 'Registering',
        PassStage.normalize => 'Normalizing',
        PassStage.integrate => 'Integrating',
        PassStage.write => 'Writing',
        PassStage.align => 'Aligning',
        PassStage.combine => 'Combining',
        PassStage.draft => 'Drafting',
      };

  /// The stages one filter's lane runs.
  static const List<PassStage> laneStages = <PassStage>[
    PassStage.calibrate,
    PassStage.register,
    PassStage.normalize,
    PassStage.integrate,
    PassStage.write,
  ];
}

enum PassStepState { waiting, running, done }

/// One sub and what the pass measured on it.
@immutable
class PassFrame {
  const PassFrame({
    required this.filter,
    required this.index,
    required this.name,
    this.capturedAt,
    this.stars,
    this.fwhm,
    this.eccentricity,
    this.background,
    this.noise,
    this.snr,
    this.weight,
    this.rmsPx,
    this.dx,
    this.dy,
    this.rotationDeg,
    this.accepted = true,
    this.reason,
    this.isReference = false,
    this.thumbnail,
  });

  final String filter;

  /// 1-based position in the lane, in capture order.
  final int index;
  final String name;
  final DateTime? capturedAt;
  final int? stars;
  final double? fwhm;
  final double? eccentricity;
  final double? background;
  final double? noise;
  final double? snr;
  final double? weight;
  final double? rmsPx;

  /// The registration offset onto the lane's reference, in pixels.
  final double? dx;
  final double? dy;
  final double? rotationDeg;
  final bool accepted;
  final String? reason;
  final bool isReference;
  final ui.Image? thumbnail;

  double? get shift =>
      dx == null || dy == null ? null : math.sqrt(dx! * dx! + dy! * dy!);
}

/// One stage of one lane on the pass clock: when it started, when it ended,
/// and when each of its subs finished. [end] null is a stage still open with
/// no measured end.
@immutable
class PassSpan {
  const PassSpan({
    required this.stage,
    required this.start,
    required this.end,
    this.ticks = const <Duration>[],
    this.estimated = false,
  });

  final PassStage stage;
  final Duration start;
  final Duration? end;

  /// The offset at which each sub of this stage finished, in order.
  final List<Duration> ticks;

  /// Timed from an earlier pass rather than this one.
  final bool estimated;

  int doneAt(Duration t) => ticks.where((d) => d <= t).length;

  PassStepState stateAt(Duration t) {
    if (t < start) return PassStepState.waiting;
    final e = end;
    if (e != null && t >= e) return PassStepState.done;
    return PassStepState.running;
  }
}

/// One filter's subs and the stages that turn them into its master.
@immutable
class PassLane {
  const PassLane({
    required this.filter,
    required this.frames,
    required this.spans,
    required this.exposureSec,
    this.masterNoise,
    this.framesIntegrated,
    this.framesRejected,
    this.rejectionMap,
    this.masterPreview,
    this.referencePreview,
  });

  final String filter;
  final List<PassFrame> frames;
  final List<PassSpan> spans;
  final double exposureSec;
  final double? masterNoise;
  final int? framesIntegrated;
  final int? framesRejected;
  final ui.Image? rejectionMap;
  final ui.Image? masterPreview;

  /// The calibrated reference sub, shown until the running mean has two subs.
  final ui.Image? referencePreview;

  PassSpan span(PassStage stage) => spans.firstWhere((s) => s.stage == stage);

  Duration get start => spans.first.start;
  Duration get end => spans.last.end ?? spans.last.start;
}

/// The image integrated from the first [depth] subs and its measured noise.
@immutable
class PassDepth {
  const PassDepth({required this.depth, required this.noise, this.image});
  final int depth;

  /// Background noise per pixel, in ADU.
  final double noise;
  final ui.Image? image;
}

/// One channel master fitted onto the luminance master.
@immutable
class PassChannelFit {
  const PassChannelFit({
    required this.filter,
    required this.dx,
    required this.dy,
    required this.rotationDeg,
    required this.scale,
    required this.matched,
    required this.inliers,
    required this.rmsPx,
    this.failure,
  });

  /// A channel the fit could not place, with the registration's reason; the
  /// numbers are then meaningless.
  const PassChannelFit.failed(this.filter, String this.failure)
      : dx = 0,
        dy = 0,
        rotationDeg = 0,
        scale = 1,
        matched = 0,
        inliers = 0,
        rmsPx = 0;

  final String? failure;
  final String filter;
  final double dx;
  final double dy;
  final double rotationDeg;
  final double scale;
  final int matched;
  final int inliers;
  final double rmsPx;
}

/// A whole pass as reported, on one clock.
@immutable
class PassTimeline {
  const PassTimeline({
    required this.target,
    required this.lanes,
    required this.depths,
    required this.colorSpans,
    required this.channelFits,
    this.colorImage,
    this.colorCaption = 'Color',
    this.calibrationNote,
  });

  /// What [colorImage] is.
  final String colorCaption;

  final String target;
  final List<PassLane> lanes;

  /// The luminance lane's image at the depths the pass previewed.
  final List<PassDepth> depths;

  /// Align channels, combine color and drafts, after the lanes.
  final List<PassSpan> colorSpans;
  final List<PassChannelFit> channelFits;
  final ui.Image? colorImage;

  /// What calibration applied, as the status line says it.
  final String? calibrationNote;

  PassSnapshot at(Duration t) => PassSnapshot._(this, t);
}

/// The pass at one moment.
class PassSnapshot {
  PassSnapshot._(this.timeline, this.elapsed);

  final PassTimeline timeline;
  final Duration elapsed;

  List<PassLane> get lanes => timeline.lanes;

  /// The lane whose stages are running, or null once every lane is done.
  PassLane? get activeLane {
    for (final lane in lanes) {
      if (elapsed < lane.end) return lane;
    }
    return null;
  }

  /// The running stage and the lane it belongs to (null for the color
  /// stages).
  (PassLane?, PassSpan)? get activeSpan {
    for (final lane in lanes) {
      for (final span in lane.spans) {
        if (span.stateAt(elapsed) == PassStepState.running) return (lane, span);
      }
    }
    for (final span in timeline.colorSpans) {
      if (span.stateAt(elapsed) == PassStepState.running) return (null, span);
    }
    return null;
  }

  /// Whether [frame]'s registration measurements exist yet.
  bool measured(PassLane lane, PassFrame frame) {
    final reg = lane.span(PassStage.register);
    if (elapsed >= (reg.end ?? reg.start) && reg.end != null) return true;
    return reg.doneAt(elapsed) >= frame.index;
  }

  /// Whether [lane]'s weights exist yet (they are computed once, after every
  /// sub is registered).
  bool weighed(PassLane lane) {
    final norm = lane.span(PassStage.normalize);
    return elapsed >= norm.start;
  }

  /// Subs of [lane] whose image has reached the running mean.
  int stackedIn(PassLane lane) {
    final norm = lane.span(PassStage.normalize);
    if (norm.stateAt(elapsed) == PassStepState.done) {
      return lane.frames.where((f) => f.accepted).length;
    }
    return norm.doneAt(elapsed);
  }

  /// The depths of the luminance lane reached so far.
  List<PassDepth> get depthsReached {
    if (lanes.isEmpty) return const <PassDepth>[];
    final lead = lanes.first;
    final stacked = stackedIn(lead);
    return <PassDepth>[
      for (final d in timeline.depths)
        if (d.depth <= stacked) d,
    ];
  }

  /// Every sub of every lane whose span for [stage] finished.
  int doneCount(PassStage stage) {
    var n = 0;
    for (final lane in lanes) {
      n += lane.span(stage).doneAt(elapsed);
    }
    return n;
  }

  /// Seconds per sub [span] has taken so far on this pass, or null before
  /// its first sub finished.
  double? _rate(PassSpan span) {
    final done = span.doneAt(elapsed);
    if (done == 0) return null;
    return (span.ticks[done - 1] - span.start).inMilliseconds / 1000 / done;
  }

  /// How long [span] of [lane] runs in all, from what this pass measured:
  /// its own per-sub rate, else the first lane's rate or duration for the
  /// same stage scaled by sub count, else the duration an earlier pass
  /// recorded. The second value is true when the duration is not from this
  /// pass's measurements. Null when nothing covers it.
  (double, bool)? _duration(PassLane? lane, PassSpan span) {
    final total = span.ticks.length;
    final own = _rate(span);
    if (own != null && total > 0) return (own * total, false);
    if (lane != null && lanes.first != lane) {
      final first = lanes.first.span(span.stage);
      if (first.stateAt(elapsed) == PassStepState.done && first.end != null) {
        final scale = lane.frames.length / lanes.first.frames.length;
        return (
          (first.end! - first.start).inMilliseconds / 1000 * scale,
          false
        );
      }
      final rate = _rate(first);
      if (rate != null && total > 0) return (rate * total, false);
    }
    final end = span.end;
    if (end == null) return null;
    return ((end - span.start).inMilliseconds / 1000, true);
  }

  /// Every stage of the pass laid out on the clock: finished stages where
  /// they ran, the running one from its start to its estimated end, and the
  /// rest one after another at their estimated lengths. A stage nothing can
  /// estimate has a null end, and everything after it starts where the known
  /// part ends.
  List<PassScheduledSpan> get schedule {
    final out = <PassScheduledSpan>[];
    var cursor = Duration.zero;
    void add(PassLane? lane, PassSpan span) {
      final state = span.stateAt(elapsed);
      if (state == PassStepState.done) {
        out.add(PassScheduledSpan(
          filter: lane?.filter,
          stage: span.stage,
          start: span.start,
          end: span.end,
          drawnEnd: span.end!,
          state: state,
          done: span.ticks.length,
          total: span.ticks.length,
          ticks: span.ticks,
        ));
        cursor = span.end!;
        return;
      }
      final start = state == PassStepState.running ? span.start : cursor;
      final length = _duration(lane, span);
      Duration? end;
      if (length != null) {
        end = start + Duration(milliseconds: (length.$1 * 1000).round());
        if (state == PassStepState.running && end < elapsed) end = elapsed;
      }
      // A stage with no estimate still takes room on the clock, so what comes
      // after it is drawn after it; the room is marked, never counted.
      final open = end == null
          ? (state == PassStepState.running && elapsed > start
                  ? elapsed
                  : start) +
              Duration(
                  milliseconds:
                      math.max(8000, (cursor.inMilliseconds * 0.06).round()))
          : null;
      out.add(PassScheduledSpan(
        filter: lane?.filter,
        stage: span.stage,
        start: start,
        end: end,
        drawnEnd: end ?? open!,
        state: state,
        done: span.doneAt(elapsed),
        total: span.ticks.length,
        ticks: <Duration>[
          for (final t in span.ticks)
            if (t <= elapsed) t,
        ],
        estimated: length?.$2 ?? false,
      ));
      cursor = end ?? open!;
    }

    for (final lane in lanes) {
      for (final span in lane.spans) {
        add(lane, span);
      }
    }
    for (final span in timeline.colorSpans) {
      add(null, span);
    }
    return out;
  }

  /// The time still to run as far as it can be estimated, and whether every
  /// stage still to come had an estimate.
  (Duration, bool) get remaining {
    var known = Duration.zero;
    var complete = true;
    var from = elapsed;
    for (final s in schedule) {
      if (s.state == PassStepState.done) continue;
      final end = s.end;
      if (end == null) {
        complete = false;
        continue;
      }
      final begin = s.start > from ? s.start : from;
      if (end > begin) known += end - begin;
      from = end;
    }
    return (known, complete);
  }

  /// The image the screen shows now and a line saying what it is.
  (ui.Image?, String) get image {
    final combine = timeline.colorSpans
        .where((s) => s.stage == PassStage.combine)
        .firstOrNull;
    if (combine != null &&
        combine.stateAt(elapsed) != PassStepState.waiting &&
        timeline.colorImage != null) {
      return (timeline.colorImage, timeline.colorCaption);
    }
    // The newest lane with a master, else the luminance depth reached.
    for (final lane in lanes.reversed) {
      if (lane.span(PassStage.write).stateAt(elapsed) == PassStepState.done &&
          lane != lanes.first) {
        final active = activeLane;
        if (active != null && active != lane) {
          // A later lane is still stacking; keep showing the luminance master.
          break;
        }
        return (lane.masterPreview, '${lane.filter} master');
      }
    }
    final lead = lanes.first;
    if (lead.span(PassStage.write).stateAt(elapsed) == PassStepState.done) {
      return (
        lead.masterPreview,
        '${lead.filter} master · ${lead.framesIntegrated ?? lead.frames.length} subs',
      );
    }
    final reached = depthsReached;
    if (reached.isEmpty) {
      final ref = lead.frames.where((f) => f.isReference).firstOrNull;
      final reg = lead.span(PassStage.register);
      if (ref != null &&
          reg.doneAt(elapsed) > 0 &&
          lead.referencePreview != null) {
        return (
          lead.referencePreview,
          '${lead.filter} reference, sub ${ref.index} · one ${lead.exposureSec.round()} s exposure',
        );
      }
      return (null, 'No subs stacked yet');
    }
    final d = reached.last;
    return (
      d.image,
      '${lead.filter} · mean of the first ${d.depth} subs',
    );
  }
}

/// A compact clock for elapsed and remaining time: `4:05`, `1:02:10`.
String passClock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// One stage placed on the pass clock by [PassSnapshot.schedule].
@immutable
class PassScheduledSpan {
  const PassScheduledSpan({
    required this.filter,
    required this.stage,
    required this.start,
    required this.end,
    required this.drawnEnd,
    required this.state,
    required this.done,
    required this.total,
    this.ticks = const <Duration>[],
    this.estimated = false,
  });

  /// Where the block ends on the chart: [end], or for a stage with no
  /// estimate a marked placeholder.
  final Duration drawnEnd;

  /// The lane's filter; null for the color stages.
  final String? filter;
  final PassStage stage;
  final Duration start;

  /// Null when nothing measured estimates it.
  final Duration? end;
  final PassStepState state;
  final int done;
  final int total;

  /// The finish offsets of the subs done so far.
  final List<Duration> ticks;

  /// Timed from an earlier pass rather than measured on this one.
  final bool estimated;
}
