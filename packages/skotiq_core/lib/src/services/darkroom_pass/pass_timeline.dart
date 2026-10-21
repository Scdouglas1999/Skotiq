/// A Darkroom pass read from its [PassLog]: the pass on one clock, as stages
/// per filter lane and the stages after them, with every sub's measurements.
///
/// [PassTimeline.fromLog] folds the reports into the timeline once; [at]
/// answers what the pass looked like at one moment. A value is visible only
/// once the report that carries it was made, so a moment never shows a number
/// the pipeline had not produced yet, and a running pass and its finished
/// record are drawn by the same code.
library;

import 'dart:math' as math;

import 'pass_log.dart';

/// The stages of a pass, in the order they run.
enum PassStage {
  calibrate,
  register,
  normalize,
  integrate,
  write,
  finish,
  align,
  combine,
  draft;

  String get label => switch (this) {
    PassStage.calibrate => 'Calibrate',
    PassStage.register => 'Register',
    PassStage.normalize => 'Normalize',
    PassStage.integrate => 'Integrate',
    PassStage.write => 'Write',
    PassStage.finish => 'Solve and save',
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
    PassStage.finish => 'Solving and saving',
    PassStage.align => 'Aligning',
    PassStage.combine => 'Combining',
    PassStage.draft => 'Drafting',
  };

  bool get isLaneStage => index <= PassStage.finish.index;

  /// The key a stored rate is kept under.
  String get key => name;
}

enum PassStepState { waiting, running, done, notRun }

/// One sub and what the pass measured on it.
class PassFrame {
  PassFrame({required this.lane, required this.index, this.name});

  final String lane;

  /// 1-based position in the lane, in the order the run was given the subs.
  final int index;
  String? name;
  double? exposureSec;
  String? dateObs;

  /// When the sub was loaded and calibrated, and when it was registered.
  Duration? calibratedAt;
  Duration? registeredAt;

  int? stars;
  double? fwhm;
  double? eccentricity;
  double? background;
  double? noise;
  double? snr;
  double? rmsPx;
  int? matched;
  int? inliers;
  double? dx;
  double? dy;
  double? rotationDeg;
  bool accepted = true;
  String? reason;
  bool isReference = false;
  double? weight;

  double? get shift =>
      dx == null || dy == null ? null : math.sqrt(dx! * dx! + dy! * dy!);

  /// When the sub was captured, from its DATE-OBS.
  DateTime? get capturedAt {
    final d = dateObs;
    if (d == null || d.isEmpty) return null;
    return DateTime.tryParse(d.endsWith('Z') ? d : '${d}Z')?.toLocal();
  }
}

/// One stage on the pass clock. [start] null is a stage that has not begun;
/// [end] null one that has not finished.
class PassSpan {
  PassSpan(this.stage, {this.total});

  final PassStage stage;
  Duration? start;
  Duration? end;
  bool failed = false;

  /// The offset at which each sub of this stage finished, in order.
  final List<Duration> ticks = <Duration>[];

  /// How many subs (or items) the stage handles, when known.
  int? total;

  int doneAt(Duration t) => ticks.where((d) => d <= t).length;

  PassStepState stateAt(Duration t, {bool ended = false}) {
    final s = start;
    if (s == null || t < s) {
      return ended ? PassStepState.notRun : PassStepState.waiting;
    }
    final e = end;
    if (e != null && t >= e) return PassStepState.done;
    return ended ? PassStepState.notRun : PassStepState.running;
  }
}

/// The running mean of a lane's normalized subs at one depth.
class PassDepth {
  const PassDepth({
    required this.at,
    required this.depth,
    this.noise,
    this.imagePath,
  });

  final Duration at;
  final int depth;

  /// Background noise per pixel, in ADU, measured on the binned mean.
  final double? noise;

  /// The preview PNG written at this depth, when one was.
  final String? imagePath;
}

/// One filter's subs and the stages that turn them into its master.
class PassLane {
  PassLane(this.lane, {this.plannedSubs, this.exposureSec});

  final String lane;
  int? plannedSubs;
  double? exposureSec;
  final List<PassFrame> frames = <PassFrame>[];
  final Map<PassStage, PassSpan> _spans = <PassStage, PassSpan>{};
  final List<PassDepth> depths = <PassDepth>[];

  String? referencePath;
  Duration? referenceAt;
  Duration? weightedAt;
  String? calibrationNote;
  double? masterNoise;
  int? framesIntegrated;
  double? rejectedFraction;
  String? masterPreviewPath;
  String? rejectionMapPreviewPath;
  String? failure;

  /// Whether the service solves and saves the master after integrating it.
  bool finishing = false;

  PassSpan span(PassStage stage) =>
      _spans.putIfAbsent(stage, () => PassSpan(stage));

  List<PassSpan> get spans => <PassSpan>[
    for (final s in PassStage.values)
      if (s.isLaneStage && (s != PassStage.finish || finishing)) span(s),
  ];

  int get subCount => frames.isNotEmpty ? frames.length : (plannedSubs ?? 0);
}

/// One channel master fitted onto the luminance master.
class PassChannelFit {
  const PassChannelFit({
    required this.lane,
    required this.at,
    this.dx,
    this.dy,
    this.rotationDeg,
    this.matched,
    this.inliers,
    this.rmsPx,
    this.failure,
  });

  final String lane;
  final Duration at;
  final double? dx;
  final double? dy;
  final double? rotationDeg;
  final int? matched;
  final int? inliers;
  final double? rmsPx;

  /// Why the channel could not be placed, as the registration said it.
  final String? failure;

  double? get shift =>
      dx == null || dy == null ? null : math.sqrt(dx! * dx! + dy! * dy!);
}

/// A pass as reported, on one clock that starts at its first report.
class PassTimeline {
  PassTimeline._(this.runId, this.startedAt);

  final String runId;
  final DateTime startedAt;
  String? target;
  int? sessionId;

  /// The offset of the newest report.
  Duration recorded = Duration.zero;
  bool ended = false;
  String? failure;
  final List<PassLane> lanes = <PassLane>[];
  final Map<PassStage, PassSpan> colorSpans = <PassStage, PassSpan>{};
  final List<PassChannelFit> channelFits = <PassChannelFit>[];
  String? colorPreviewPath;
  Duration? colorPreviewAt;

  /// Stored seconds per sub (lane stages) or per item (later stages) from an
  /// earlier pass, by [PassStage.key].
  Map<String, double> history = const <String, double>{};

  /// Fold [log] into a timeline.
  static PassTimeline fromLog(
    PassLog log, {
    Map<String, double> history = const <String, double>{},
  }) {
    final start = log.startedAt ?? 0;
    final tl = PassTimeline._(
      log.runId,
      DateTime.fromMillisecondsSinceEpoch(start),
    )..history = history;
    PassLane? current;

    PassLane laneNamed(String name) {
      for (final l in tl.lanes) {
        if (l.lane == name) return l;
      }
      final l = PassLane(name);
      tl.lanes.add(l);
      return l;
    }

    PassFrame frame(PassLane lane, int index) {
      while (lane.frames.length < index) {
        lane.frames.add(
          PassFrame(lane: lane.lane, index: lane.frames.length + 1),
        );
      }
      return lane.frames[index - 1];
    }

    PassSpan color(PassStage stage) =>
        tl.colorSpans.putIfAbsent(stage, () => PassSpan(stage));

    double? d(Object? v) => (v as num?)?.toDouble();
    int? i(Object? v) => (v as num?)?.toInt();

    for (final e in log.entries) {
      final at = Duration(milliseconds: e.t - start);
      if (at > tl.recorded) tl.recorded = at;
      final x = e.detail;
      switch (e.kind) {
        case PassKinds.passPlanned:
          tl.target = x['target'] as String?;
          tl.sessionId = i(x['sessionId']);
          for (final raw in (x['lanes'] as List? ?? const <Object>[])) {
            if (raw is! Map) continue;
            final l = laneNamed('${raw['lane']}')
              ..plannedSubs = i(raw['subs'])
              ..exposureSec = d(raw['exposure'])
              ..finishing = x['finishing'] == true;
            l.span(PassStage.calibrate).total = l.plannedSubs;
          }
          if (x['color'] == true) {
            color(PassStage.align).total = math.max(0, tl.lanes.length - 1);
            color(PassStage.combine);
          }
          final drafts = i(x['drafts']);
          if (drafts != null && drafts > 0) {
            color(PassStage.draft).total = drafts;
          }
        case PassKinds.runStarted:
          final lane = current = laneNamed(
            '${x['lane'] ?? 'Lane ${tl.lanes.length + 1}'}',
          );
          final names = (x['names'] as List? ?? const <Object>[]);
          final exposures = (x['exposures'] as List? ?? const <Object>[]);
          lane.frames.clear();
          for (var k = 0; k < names.length; k++) {
            lane.frames.add(
              PassFrame(lane: lane.lane, index: k + 1, name: '${names[k]}')
                ..exposureSec = k < exposures.length ? d(exposures[k]) : null,
            );
          }
          if (lane.frames.isNotEmpty) {
            lane.exposureSec ??= lane.frames.first.exposureSec;
          }
          final subs = i(x['subs']) ?? lane.frames.length;
          lane.span(PassStage.calibrate)
            ..start = at
            ..total = subs;
          lane.span(PassStage.register).total = subs;
          final cal = x['calibration'];
          if (cal is Map) {
            final applied = <String>[
              if (cal['dark'] == true) 'dark',
              if (cal['flat'] == true) 'flat',
              if (cal['bias'] == true) 'bias',
            ];
            final cosmetic = cal['cosmetic'] == true;
            lane.calibrationNote = applied.isEmpty
                ? (cosmetic
                      ? 'cosmetic correction only, no dark, flat or bias'
                      : 'no calibration frames')
                : '${applied.join(', ')}${cosmetic ? ' and cosmetic correction' : ''}';
          }
        case PassKinds.calibrated:
          final lane = current;
          if (lane == null) break;
          lane.span(PassStage.calibrate).ticks.add(at);
          final f = frame(
            lane,
            i(x['index']) ?? lane.span(PassStage.calibrate).ticks.length,
          );
          f
            ..calibratedAt = at
            ..dateObs = x['dateObs'] as String?;
        case PassKinds.referenceChoosing:
          final lane = current;
          if (lane == null) break;
          lane.span(PassStage.calibrate).end ??= at;
          lane.span(PassStage.register).start ??= at;
        case PassKinds.referenceChosen:
          final lane = current;
          if (lane == null) break;
          lane
            ..referencePath = x['path'] as String?
            ..referenceAt = at;
          final idx = i(x['index']);
          if (idx != null) frame(lane, idx).isReference = true;
        case PassKinds.registered:
          final lane = current;
          if (lane == null) break;
          final reg = lane.span(PassStage.register);
          lane.span(PassStage.calibrate).end ??= at;
          reg.start ??= at;
          reg.ticks.add(at);
          final f = frame(lane, i(x['index']) ?? reg.ticks.length);
          final t = (x['transform'] as List?)?.cast<num>();
          f
            ..registeredAt = at
            ..name ??= x['name'] as String?
            ..isReference = x['reference'] == true || f.isReference
            ..accepted = x['accepted'] != false
            ..reason = x['reason'] as String?
            ..stars = i(x['stars'])
            ..fwhm = d(x['fwhm'])
            ..eccentricity = d(x['eccentricity'])
            ..background = d(x['background'])
            ..noise = d(x['noise'])
            ..snr = d(x['snr'])
            ..rmsPx = d(x['rmsPx'])
            ..matched = i(x['matched'])
            ..inliers = i(x['inliers']);
          if (t != null && t.length == 9) {
            f
              ..dx = t[2].toDouble()
              ..dy = t[5].toDouble()
              ..rotationDeg =
                  math.atan2(t[3].toDouble(), t[0].toDouble()) * 180 / math.pi;
          }
        case PassKinds.weighted:
          final lane = current;
          if (lane == null) break;
          lane.weightedAt = at;
          lane.span(PassStage.register).end ??= at;
          var accepted = 0;
          for (final w in (x['weights'] as List? ?? const <Object>[])) {
            if (w is! Map) continue;
            final idx = i(w['index']);
            if (idx == null) continue;
            frame(lane, idx).weight = d(w['weight']);
            accepted++;
          }
          lane.span(PassStage.normalize)
            ..start = at
            ..total = accepted;
        case PassKinds.normalized:
          final lane = current;
          if (lane == null) break;
          lane.span(PassStage.normalize)
            ..start ??= at
            ..ticks.add(at);
        case PassKinds.runningPreview:
          final lane = current;
          if (lane == null) break;
          lane.depths.add(
            PassDepth(
              at: at,
              depth: i(x['subs']) ?? lane.depths.length + 1,
              noise: d(x['noise']),
              imagePath: x['path'] as String?,
            ),
          );
        case PassKinds.integrating:
          final lane = current;
          if (lane == null) break;
          lane.span(PassStage.normalize).end ??= at;
          lane.span(PassStage.integrate).start = at;
        case PassKinds.integrated:
          final lane = current;
          if (lane == null) break;
          lane.span(PassStage.integrate).end = at;
          lane.span(PassStage.write).start = at;
          lane
            ..framesIntegrated = i(x['frames'])
            ..rejectedFraction = d(x['rejectedFraction'])
            ..masterNoise = d(x['noise']);
        case PassKinds.written:
          final lane = current;
          if (lane == null) break;
          lane.span(PassStage.write).end = at;
          lane
            ..masterPreviewPath = x['previewPath'] as String?
            ..rejectionMapPreviewPath = x['rejectionMapPreviewPath'] as String?;
        case PassKinds.runEnded:
          final lane = laneNamed('${x['lane'] ?? current?.lane ?? ''}');
          if (x['ok'] == false) {
            lane.failure = '${x['error'] ?? 'the integration stopped'}';
            for (final s in lane.spans) {
              if (s.start != null && s.end == null) {
                s
                  ..end = at
                  ..failed = true;
              }
            }
          }
        case PassKinds.laneFinishing:
          final lane = laneNamed('${x['lane']}')..finishing = true;
          lane.span(PassStage.finish).start = at;
        case PassKinds.laneFinished:
          final lane = laneNamed('${x['lane']}')..finishing = true;
          final s = lane.span(PassStage.finish);
          s.start ??= at;
          s.end = at;
          if (x['ok'] == false) {
            s.failed = true;
            lane.failure ??= '${x['error'] ?? 'the master could not be saved'}';
          }
        case PassKinds.channelAligned:
          final s = color(PassStage.align);
          s.start ??= at - Duration(milliseconds: i(x['ms']) ?? 0);
          s.ticks.add(at);
          final tr = (x['transform'] as List?)?.cast<num>();
          tl.channelFits.add(
            PassChannelFit(
              lane: '${x['filter'] ?? x['lane'] ?? '?'}',
              at: at,
              dx: tr == null ? null : tr[2].toDouble(),
              dy: tr == null ? null : tr[5].toDouble(),
              rotationDeg: tr == null
                  ? null
                  : math.atan2(tr[3].toDouble(), tr[0].toDouble()) *
                        180 /
                        math.pi,
              matched: i(x['matched']),
              inliers: i(x['inliers']),
              rmsPx: d(x['rmsPx']),
              failure: x['error'] as String?,
            ),
          );
          final want = s.total ?? math.max(0, tl.lanes.length - 1);
          if (want > 0 && s.ticks.length >= want) s.end ??= at;
        case PassKinds.combineStarted:
          color(PassStage.align).end ??= at;
          color(PassStage.combine).start = at;
        case PassKinds.combineDone:
          final s = color(PassStage.combine);
          s.start ??= at;
          s.end = at;
          tl.colorPreviewPath =
              x['previewPath'] as String? ?? x['path'] as String?;
          tl.colorPreviewAt = at;
          if (x['ok'] == false) s.failed = true;
        case PassKinds.stage:
          final stage = switch (x['stage']) {
            'align' => PassStage.align,
            'combine' => PassStage.combine,
            'draft' => PassStage.draft,
            _ => null,
          };
          if (stage == null) break;
          final s = color(stage);
          switch (x['state']) {
            case 'started':
              s.start ??= at;
              final total = i(x['total']);
              if (total != null) s.total = total;
            case 'step':
              s.start ??= at;
              s.ticks.add(at);
            case 'done':
              s.start ??= at;
              s.end = at;
              if (stage == PassStage.combine) {
                tl.colorPreviewPath =
                    x['previewPath'] as String? ?? tl.colorPreviewPath;
                tl.colorPreviewAt = at;
              }
            case 'failed':
              s.start ??= at;
              s
                ..end = at
                ..failed = true;
          }
        case PassKinds.passEnded:
          tl.ended = true;
          if (x['ok'] == false) {
            tl.failure = '${x['error'] ?? 'the pass stopped'}';
          }
      }
    }
    return tl;
  }

  /// Seconds per sub (lane stages) or per item (later stages) this finished
  /// pass took, to estimate the next pass's stages before they run.
  Map<String, double> stageRates() {
    final out = <String, double>{};
    void put(PassStage stage, double secs, int count) {
      if (count <= 0 || secs <= 0) return;
      out[stage.key] = secs / count;
    }

    for (final stage in PassStage.values.where((s) => s.isLaneStage)) {
      var secs = 0.0;
      var subs = 0;
      for (final lane in lanes) {
        final s = lane.span(stage);
        if (s.start == null || s.end == null || s.failed) continue;
        secs += (s.end! - s.start!).inMilliseconds / 1000;
        subs += s.total ?? lane.subCount;
      }
      put(stage, secs, subs);
    }
    for (final entry in colorSpans.entries) {
      final s = entry.value;
      if (s.start == null || s.end == null || s.failed) continue;
      final items = entry.key == PassStage.combine
          ? 1
          : (s.ticks.isNotEmpty ? s.ticks.length : (s.total ?? 1));
      put(entry.key, (s.end! - s.start!).inMilliseconds / 1000, items);
    }
    return out;
  }

  PassSnapshot at(Duration t) => PassSnapshot._(this, t);

  /// The pass as it stands at its newest report (a record), or [now] for one
  /// still running.
  PassSnapshot snapshot({DateTime? now}) {
    if (ended || now == null) return at(recorded);
    final live = now.difference(startedAt);
    return at(live < recorded ? recorded : live);
  }
}

/// The pass at one moment.
class PassSnapshot {
  PassSnapshot._(this.timeline, this.elapsed);

  final PassTimeline timeline;
  final Duration elapsed;

  List<PassLane> get lanes => timeline.lanes;
  bool get ended => timeline.ended && elapsed >= timeline.recorded;

  /// The lane being worked on, else the newest lane that started.
  PassLane? get focusLane {
    PassLane? last;
    for (final lane in lanes) {
      final s = lane.span(PassStage.calibrate).start;
      if (s == null || s > elapsed) continue;
      last = lane;
    }
    return last ?? (lanes.isEmpty ? null : lanes.first);
  }

  /// The running stage and its lane (null for the stages after the lanes).
  (PassLane?, PassSpan)? get activeSpan {
    if (ended) return null;
    for (final lane in lanes) {
      for (final span in lane.spans) {
        if (span.stateAt(elapsed) == PassStepState.running) return (lane, span);
      }
    }
    for (final stage in PassStage.values) {
      final span = timeline.colorSpans[stage];
      if (span != null && span.stateAt(elapsed) == PassStepState.running) {
        return (null, span);
      }
    }
    return null;
  }

  bool measured(PassLane lane, PassFrame frame) {
    final r = frame.registeredAt;
    return r != null && r <= elapsed;
  }

  bool weighed(PassLane lane) {
    final w = lane.weightedAt;
    return w != null && w <= elapsed;
  }

  /// The running-mean depths of [lane] reached so far.
  List<PassDepth> depthsOf(PassLane lane) => <PassDepth>[
    for (final d in lane.depths)
      if (d.at <= elapsed) d,
  ];

  bool written(PassLane lane) {
    final e = lane.span(PassStage.write).end;
    return e != null && e <= elapsed;
  }

  /// The image to show now and a line saying what it is.
  (String?, String) get image {
    final colorAt = timeline.colorPreviewAt;
    if (timeline.colorPreviewPath != null &&
        colorAt != null &&
        colorAt <= elapsed) {
      return (
        timeline.colorPreviewPath,
        '${lanes.map((l) => l.lane).join(', ')} combined',
      );
    }
    final lane = focusLane;
    if (lane == null) return (null, 'Nothing stacked yet');
    if (written(lane) && lane.masterPreviewPath != null) {
      return (
        lane.masterPreviewPath,
        '${lane.lane} master · ${lane.framesIntegrated ?? lane.frames.where((f) => f.accepted).length} subs',
      );
    }
    final depths = depthsOf(lane);
    for (final d in depths.reversed) {
      if (d.imagePath != null) {
        return (
          d.imagePath,
          '${lane.lane} · mean of the first ${d.depth} subs',
        );
      }
    }
    final refAt = lane.referenceAt;
    if (lane.referencePath != null && refAt != null && refAt <= elapsed) {
      final ref = lane.frames.where((f) => f.isReference).firstOrNull;
      final exp = lane.exposureSec;
      return (
        lane.referencePath,
        '${lane.lane} reference${ref == null ? '' : ', sub ${ref.index}'}'
            '${exp == null ? '' : ' · one ${exp.round()} s exposure'}',
      );
    }
    return (null, 'Nothing stacked yet');
  }

  /// Seconds per sub [stage] has taken on this pass so far, over every lane
  /// that has run it.
  double? passRate(PassStage stage) {
    var secs = 0.0;
    var subs = 0;
    for (final lane in lanes) {
      final s = lane.span(stage);
      final start = s.start;
      if (start == null || start > elapsed || s.failed) continue;
      final end = s.end;
      if (end != null && end <= elapsed) {
        secs += (end - start).inMilliseconds / 1000;
        subs += s.total ?? lane.subCount;
        continue;
      }
      final done = s.doneAt(elapsed);
      if (done > 0) {
        secs += (s.ticks[done - 1] - start).inMilliseconds / 1000;
        subs += done;
      }
    }
    return subs > 0 && secs > 0 ? secs / subs : null;
  }

  /// Every stage laid out on the clock: finished stages where they ran, the
  /// running one from its start to its estimated end, the rest one after
  /// another at their estimated lengths. A stage nothing estimates has a null
  /// end and a marked placeholder width; a stage a finished pass never ran is
  /// [PassStepState.notRun].
  List<PassScheduledSpan> get schedule {
    final out = <PassScheduledSpan>[];
    var cursor = Duration.zero;
    final done = ended;

    void add(PassLane? lane, PassSpan span, int units) {
      final state = span.stateAt(elapsed, ended: done);
      final visibleTicks = <Duration>[
        for (final t in span.ticks)
          if (t <= elapsed) t,
      ];
      if (state == PassStepState.done) {
        out.add(
          PassScheduledSpan(
            lane: lane?.lane,
            stage: span.stage,
            start: span.start!,
            end: span.end,
            drawnEnd: span.end!,
            state: state,
            done: visibleTicks.length,
            total: span.total ?? visibleTicks.length,
            ticks: visibleTicks,
            failed: span.failed,
          ),
        );
        if (span.end! > cursor) cursor = span.end!;
        return;
      }
      if (state == PassStepState.notRun) {
        final at = span.start ?? cursor;
        out.add(
          PassScheduledSpan(
            lane: lane?.lane,
            stage: span.stage,
            start: at,
            end: at,
            drawnEnd: at,
            state: state,
            done: visibleTicks.length,
            total: span.total ?? 0,
            ticks: visibleTicks,
            failed: span.failed,
          ),
        );
        return;
      }
      final start = state == PassStepState.running ? span.start! : cursor;
      final (length, fromHistory) = _length(lane, span, units);
      Duration? end;
      if (length != null) {
        end = start + Duration(milliseconds: (length * 1000).round());
        if (state == PassStepState.running && end < elapsed) end = elapsed;
      }
      final open =
          end ??
          ((state == PassStepState.running && elapsed > start
                  ? elapsed
                  : start) +
              Duration(
                milliseconds: math.max(
                  8000,
                  (cursor.inMilliseconds * 0.06).round(),
                ),
              ));
      out.add(
        PassScheduledSpan(
          lane: lane?.lane,
          stage: span.stage,
          start: start,
          end: end,
          drawnEnd: open,
          state: state,
          done: visibleTicks.length,
          total: span.total ?? units,
          ticks: visibleTicks,
          estimated: fromHistory,
        ),
      );
      cursor = open;
    }

    for (final lane in lanes) {
      for (final span in lane.spans) {
        add(lane, span, span.total ?? lane.subCount);
      }
    }
    for (final stage in PassStage.values) {
      final span = timeline.colorSpans[stage];
      if (span == null) continue;
      final units = stage == PassStage.combine ? 1 : (span.total ?? 1);
      add(null, span, units);
    }
    return out;
  }

  /// Seconds the span takes in all and whether that came from an earlier
  /// pass, or null when nothing covers it.
  (double?, bool) _length(PassLane? lane, PassSpan span, int units) {
    final done = span.doneAt(elapsed);
    final start = span.start;
    if (done > 0 && start != null && units > 0) {
      final own = (span.ticks[done - 1] - start).inMilliseconds / 1000 / done;
      return (own * units, false);
    }
    if (lane != null) {
      final rate = passRate(span.stage);
      if (rate != null) return (rate * units, false);
    }
    final stored = timeline.history[span.stage.key];
    if (stored != null) return (stored * units, true);
    return (null, false);
  }

  /// The time still to run as far as it can be estimated, and whether every
  /// stage still to come had an estimate.
  (Duration, bool) get remaining {
    var known = Duration.zero;
    var complete = true;
    var from = elapsed;
    for (final s in schedule) {
      if (s.state == PassStepState.done || s.state == PassStepState.notRun) {
        continue;
      }
      final end = s.end;
      if (end == null) {
        complete = false;
        continue;
      }
      final begin = s.start > from ? s.start : from;
      if (end > begin) known += end - begin;
      if (end > from) from = end;
    }
    return (known, complete);
  }
}

/// One stage placed on the pass clock by [PassSnapshot.schedule].
class PassScheduledSpan {
  const PassScheduledSpan({
    required this.lane,
    required this.stage,
    required this.start,
    required this.end,
    required this.drawnEnd,
    required this.state,
    required this.done,
    required this.total,
    this.ticks = const <Duration>[],
    this.estimated = false,
    this.failed = false,
  });

  /// The lane; null for the stages after the lanes.
  final String? lane;
  final PassStage stage;
  final Duration start;

  /// Null when nothing measured estimates it.
  final Duration? end;

  /// Where the block ends on a chart: [end], or a marked placeholder.
  final Duration drawnEnd;
  final PassStepState state;
  final int done;
  final int total;
  final List<Duration> ticks;

  /// Timed from an earlier pass rather than this one.
  final bool estimated;
  final bool failed;
}

/// A compact clock: `4:05`, `1:02:10`.
String passClock(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// A sub's rejection reason as the operator reads it. The registration's own
/// wording is kept for anything this does not recognize.
String passReadableReason(String reason) {
  final m = RegExp(
    r'only (\d+) correspondences/inliers, need >= (\d+)',
  ).firstMatch(reason);
  if (m != null) {
    return 'no stars matched the reference (${m.group(1)} matched, '
        '${m.group(2)} needed)';
  }
  return reason;
}
