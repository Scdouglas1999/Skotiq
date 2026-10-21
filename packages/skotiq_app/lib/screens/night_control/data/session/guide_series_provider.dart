// The guiding chart: RA and Dec error, RMS, dither marks.
//
// The samples come from the guider's GuideStep events, which carry PHD2's
// raw distances in guide-camera pixels. They are shown in arcseconds only
// when the guider reports its pixel scale, and in pixels otherwise; nothing
// assumes a scale. `guideGraphProvider` turns a missing axis into 0, which
// draws a perfect guide step that never happened; this provider keeps its
// own buffer and drops such a sample.
//
// The buffer holds the night. The chart shows a rolling window of it (2, 5
// or 15 minutes, or the whole night thinned to the shape a chart can draw),
// and the RMS beside the chart is computed from that window's samples, so
// the chart and its numbers always describe the same span.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../night_control_contracts.dart';
import 'session_events_provider.dart';
import 'session_format.dart';

/// One guide step, both axes in pixels.
@immutable
class NightGuideSample {
  const NightGuideSample(this.t, this.raPx, this.decPx);

  final DateTime t;
  final double raPx;
  final double decPx;
}

/// The night's guide steps (up to [NightGuideSamplesNotifier.retention]),
/// oldest first.
final nightGuideSamplesProvider =
    StateNotifierProvider<NightGuideSamplesNotifier, List<NightGuideSample>>(
  NightGuideSamplesNotifier.new,
);

class NightGuideSamplesNotifier extends StateNotifier<List<NightGuideSample>> {
  NightGuideSamplesNotifier(this._ref) : super(const <NightGuideSample>[]) {
    _bind(_ref.read(backendProvider));
    _ref.listen<SkotiqBackend>(backendProvider, (_, next) => _bind(next));
  }

  final Ref _ref;
  StreamSubscription<SkotiqEvent>? _sub;
  int _generation = 0;

  /// How far back the buffer reaches: a long winter night.
  static const Duration retention = Duration(hours: 16);

  /// A guard on top of [retention]: sixteen hours at one step a second.
  static const int maxSamples = 60000;

  /// The span the guide tab's scatter and RMS describe.
  static const Duration recent = Duration(minutes: 10);

  void _bind(SkotiqBackend backend) {
    final generation = ++_generation;
    final previous = _sub;
    _sub = backend.eventStream.listen((event) {
      if (generation != _generation || !mounted) return;
      if (event.category != EventCategory.guiding ||
          event.eventType != 'GuideStep') {
        return;
      }
      final sample = nightGuideSampleFrom(event);
      if (sample != null) add(sample);
    });
    previous?.cancel();
  }

  void add(NightGuideSample sample) {
    final current = state;
    final cutoff = sample.t.subtract(retention);
    var start = 0;
    while (start < current.length && current[start].t.isBefore(cutoff)) {
      start++;
    }
    start = math.max(start, current.length + 1 - maxSamples);
    state = <NightGuideSample>[...current.skip(start), sample];
  }

  @override
  void dispose() {
    _generation++;
    _sub?.cancel();
    super.dispose();
  }
}

/// The sample a GuideStep event carries, or null when either axis is
/// missing or not a number. Such a step is dropped, not drawn at 0.
NightGuideSample? nightGuideSampleFrom(SkotiqEvent event) {
  double? axis(String raw, String fallback) {
    final value = event.data[raw] ?? event.data[fallback];
    if (value is! num) return null;
    final d = value.toDouble();
    return d.isFinite ? d : null;
  }

  final ra = axis('RADistanceRaw', 'raPx');
  final dec = axis('DECDistanceRaw', 'decPx');
  if (ra == null || dec == null) return null;
  final t = event.timestamp > 0
      ? DateTime.fromMillisecondsSinceEpoch(event.timestamp)
      : DateTime.now();
  return NightGuideSample(t, ra, dec);
}

/// The guide tab's span: the last [NightGuideSamplesNotifier.recent] of
/// guide steps.
final nightGuideRecentSamplesProvider = Provider<List<NightGuideSample>>((
  ref,
) {
  final samples = ref.watch(nightGuideSamplesProvider);
  if (samples.isEmpty) return samples;
  return _since(
    samples,
    samples.last.t.subtract(NightGuideSamplesNotifier.recent),
  );
});

/// The span the guiding chart shows.
enum NightGuideWindow {
  twoMinutes(Duration(minutes: 2)),
  fiveMinutes(Duration(minutes: 5)),
  fifteenMinutes(Duration(minutes: 15)),

  /// Everything in the buffer.
  night(null);

  const NightGuideWindow(this.duration);

  /// Null for [night].
  final Duration? duration;
}

/// The guiding chart's window. Five minutes shows single guide steps; the
/// night shows the trend.
final nightGuideWindowProvider = StateProvider<NightGuideWindow>(
  (ref) => NightGuideWindow.fiveMinutes,
);

/// The samples from [from] on; [samples] is in time order.
List<NightGuideSample> _since(List<NightGuideSample> samples, DateTime from) {
  var lo = 0;
  var hi = samples.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (samples[mid].t.isBefore(from)) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo == 0 ? samples : samples.sublist(lo);
}

/// The samples [window] reaches back from the newest one.
List<NightGuideSample> nightGuideInWindow(
  List<NightGuideSample> samples,
  NightGuideWindow window,
) {
  final duration = window.duration;
  if (samples.isEmpty || duration == null) return samples;
  return _since(samples, samples.last.t.subtract(duration));
}

/// A pause longer than this between two guide steps (a flip, an autofocus
/// run, guiding stopped) is drawn as a gap rather than a straight line.
const Duration kNightGuideGap = Duration(seconds: 60);

/// The most points one axis of the guiding chart draws; about one per pixel
/// pair at the chart's widest.
const int kNightGuideMaxPoints = 600;

/// [points] (one guide axis, in time order) as the chart draws them. Up to
/// [maxPoints] pass through unchanged; past that the span is cut into equal
/// time buckets and each keeps its lowest and highest point, in time order,
/// so a spike survives the thinning. A pause longer than [gap] becomes a
/// null point, which the chart draws as a break.
List<SeriesPoint> nightGuideTrace(
  List<SeriesPoint> points, {
  int maxPoints = kNightGuideMaxPoints,
  Duration gap = kNightGuideGap,
}) {
  final out = <SeriesPoint>[];
  final values = <SeriesPoint>[
    for (final p in points)
      if (p.y != null && p.y!.isFinite) p,
  ];
  if (values.isEmpty) return out;
  final first = values.first.t.millisecondsSinceEpoch;
  final span = values.last.t.millisecondsSinceEpoch - first;
  final thin = values.length > maxPoints && span > 0;
  // Two points per bucket.
  final buckets = maxPoints ~/ 2;
  final bucketMs = thin ? span / buckets : 0.0;

  SeriesPoint? lo;
  SeriesPoint? hi;
  int? bucket;
  void flush() {
    final a = lo;
    final b = hi;
    if (a == null || b == null) return;
    if (identical(a, b)) {
      out.add(a);
    } else if (a.t.isAfter(b.t)) {
      out
        ..add(b)
        ..add(a);
    } else {
      out
        ..add(a)
        ..add(b);
    }
    lo = null;
    hi = null;
  }

  DateTime? previous;
  for (final p in values) {
    if (previous != null && p.t.difference(previous) > gap) {
      flush();
      out.add(SeriesPoint(p.t, null));
    }
    previous = p.t;
    if (!thin) {
      out.add(p);
      continue;
    }
    // The newest point closes the last bucket rather than opening one.
    final index = math.min(
      buckets - 1,
      ((p.t.millisecondsSinceEpoch - first) / bucketMs).floor(),
    );
    if (index != bucket) {
      flush();
      bucket = index;
    }
    if (lo == null || p.y! < lo!.y!) lo = p;
    if (hi == null || p.y! > hi!.y!) hi = p;
  }
  flush();
  return out;
}

/// The smallest round value at or above [value]: 1, 1.5, 2, 2.5, 3, 4, 5,
/// 6, 8 times a power of ten.
double nightNiceCeil(double value) {
  if (!(value > 0) || !value.isFinite) return value;
  final exponent = (math.log(value) / math.ln10).floor();
  final power = math.pow(10, exponent).toDouble();
  for (final m in const <double>[1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]) {
    final candidate = m * power;
    // Tolerate float noise such as 0.5000000001.
    if (candidate >= value * (1 - 1e-9)) {
      return double.parse(candidate.toStringAsPrecision(6));
    }
  }
  return 10 * power;
}

/// The guiding chart's half-height: the scale runs from minus to plus this.
///
/// Wide enough for everything when nothing stands out, but never wider than
/// five robust sigmas (1.4826 times the median absolute error), so one dither
/// or a lost star's 200 px excursion cannot flatten the trace; those points
/// are drawn at the edge, marked off scale. Never below [floor], so steady
/// guiding does not magnify noise into waves. Rounded up to a round value.
double nightGuideSpan(Iterable<double> values, {double floor = 0.5}) {
  final magnitudes = <double>[
    for (final v in values)
      if (v.isFinite) v.abs(),
  ]..sort();
  if (magnitudes.isEmpty) return floor;
  final peak = magnitudes.last;
  final mid = magnitudes.length ~/ 2;
  final median = magnitudes.length.isOdd
      ? magnitudes[mid]
      : (magnitudes[mid - 1] + magnitudes[mid]) / 2;
  final limit = math.max(floor, 5 * 1.4826 * median);
  return nightNiceCeil(math.max(floor, math.min(peak, limit)));
}

double _rms(Iterable<double> values) {
  var sum = 0.0;
  var n = 0;
  for (final v in values) {
    sum += v * v;
    n++;
  }
  return math.sqrt(sum / n);
}

/// The guide camera's arcseconds per pixel as the guider reports it, or null
/// when it has not reported one; guide distances are then in pixels.
final nightGuideScaleProvider = Provider<double?>((ref) {
  final scale = ref.watch(
    guiderStateProvider.select((g) => g.pixelScaleArcsecPerPixel),
  );
  return scale != null && scale.isFinite && scale > 0 ? scale : null;
});

/// A guide distance of [px] pixels: `0.42″` when [arcsecPerPixel] is known,
/// `0.31 px` otherwise.
String nightGuideDistance(
  double px,
  double? arcsecPerPixel, {
  int decimals = 2,
}) =>
    arcsecPerPixel == null
        ? '${px.toStringAsFixed(decimals)} px'
        : '${(px * arcsecPerPixel).toStringAsFixed(decimals)}″';

/// The guiding chart's lines (arcseconds when the scale is known, else
/// pixels), dither marks and legend.
final nightGuideSeriesProvider = Provider<NightSeriesVm>((ref) {
  final window = ref.watch(nightGuideWindowProvider);
  final samples = nightGuideInWindow(
    ref.watch(nightGuideSamplesProvider),
    window,
  );
  final scale = ref.watch(nightGuideScaleProvider);
  // Pixels stay pixels when the guider has not reported a scale.
  double shown(double px) => scale == null ? px : px * scale;
  String distance(double px) => nightGuideDistance(px, scale);
  final dithers = ref.watch(
    nightSessionEventsProvider.select((events) => events.dithers),
  );
  final stats = ref.watch(guideStatsProvider);
  if (samples.isEmpty) {
    return const NightSeriesVm(
      lines: <SeriesLineVm>[
        SeriesLineVm(
          id: NightSeriesId.guideRa,
          points: <SeriesPoint>[],
          tone: SeriesTone.primary,
        ),
        SeriesLineVm(
          id: NightSeriesId.guideDec,
          points: <SeriesPoint>[],
          tone: SeriesTone.tertiary,
        ),
      ],
    );
  }
  final to = samples.last.t;
  final duration = window.duration;
  // A fixed span, so the trace scrolls rather than stretches.
  final from = duration == null ? samples.first.t : to.subtract(duration);
  final rmsRa = _rms(samples.map((s) => s.raPx));
  final rmsDec = _rms(samples.map((s) => s.decPx));
  final peak = samples.fold<double>(
    0,
    (worst, s) => math.max(worst, math.max(s.raPx.abs(), s.decPx.abs())),
  );
  // The stats notifier starts at SNR 0 before PHD2 has reported a frame; a
  // zero there is "no reading", not a star with no signal.
  final snr = stats.frameCount > 0 && stats.snr > 0 ? stats.snr : null;
  return NightSeriesVm(
    lines: <SeriesLineVm>[
      SeriesLineVm(
        id: NightSeriesId.guideRa,
        points: <SeriesPoint>[
          for (final s in samples) SeriesPoint(s.t, shown(s.raPx)),
        ],
        tone: SeriesTone.primary,
      ),
      SeriesLineVm(
        id: NightSeriesId.guideDec,
        points: <SeriesPoint>[
          for (final s in samples) SeriesPoint(s.t, shown(s.decPx)),
        ],
        tone: SeriesTone.tertiary,
      ),
    ],
    markers: <SeriesMarker>[
      for (final dither in dithers)
        if (!dither.at.isBefore(from) && !dither.at.isAfter(to))
          SeriesMarker(dither.at, SeriesMarkerKind.dither),
    ],
    from: from,
    to: to,
    legend: <MetricVm>[
      MetricVm(
        label: const NightText('nightSessionGuideRms'),
        value: distance(math.sqrt(rmsRa * rmsRa + rmsDec * rmsDec)),
      ),
      MetricVm(
        label: const NightText('nightSessionGuideRa'),
        value: distance(rmsRa),
      ),
      MetricVm(
        label: const NightText('nightSessionGuideDec'),
        value: distance(rmsDec),
      ),
      MetricVm(
        label: const NightText('nightSessionGuidePeak'),
        value: distance(peak),
      ),
      if (snr != null)
        MetricVm(
          label: const NightText('nightSessionGuideSnr'),
          value: nightFixed(snr, 0),
        ),
    ],
  );
});
