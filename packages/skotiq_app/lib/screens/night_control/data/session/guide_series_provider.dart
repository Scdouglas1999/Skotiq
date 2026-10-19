// The guiding chart: RA and Dec error in pixels, RMS, dither marks.
//
// The samples come from the guider's GuideStep events. They are pixels: the
// event carries PHD2's raw distances and nothing in the app exposes PHD2's
// pixel scale, so every label says "px" (plan N4). `guideGraphProvider`
// turns a missing axis into 0, which draws a perfect guide step that never
// happened; this provider keeps its own buffer and drops such a sample.
// The RMS beside the chart is computed from the same samples, so the chart
// and its numbers always describe the same window.

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

/// The last [NightGuideSamplesNotifier.window] of guide steps, oldest first.
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

  /// The chart's span.
  static const Duration window = Duration(minutes: 10);

  /// A guard on top of [window] for a guider stepping faster than 2 Hz.
  static const int maxSamples = 1200;

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
    final cutoff = sample.t.subtract(window);
    final next = <NightGuideSample>[
      for (final s in state)
        if (!s.t.isBefore(cutoff)) s,
      sample,
    ];
    state = next.length > maxSamples
        ? next.sublist(next.length - maxSamples)
        : next;
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

double _rms(Iterable<double> values) {
  var sum = 0.0;
  var n = 0;
  for (final v in values) {
    sum += v * v;
    n++;
  }
  return math.sqrt(sum / n);
}

String _px(double value) => '${value.toStringAsFixed(2)} px';

/// The guiding chart's lines (pixels), dither marks and legend.
final nightGuideSeriesProvider = Provider<NightSeriesVm>((ref) {
  final samples = ref.watch(nightGuideSamplesProvider);
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
  final from = samples.first.t;
  final to = samples.last.t;
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
          for (final s in samples) SeriesPoint(s.t, s.raPx),
        ],
        tone: SeriesTone.primary,
      ),
      SeriesLineVm(
        id: NightSeriesId.guideDec,
        points: <SeriesPoint>[
          for (final s in samples) SeriesPoint(s.t, s.decPx),
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
        label: const NightText('nightSessionGuideTotal'),
        value: _px(math.sqrt(rmsRa * rmsRa + rmsDec * rmsDec)),
      ),
      MetricVm(
        label: const NightText('nightSessionGuideRa'),
        value: _px(rmsRa),
      ),
      MetricVm(
        label: const NightText('nightSessionGuideDec'),
        value: _px(rmsDec),
      ),
      MetricVm(
        label: const NightText('nightSessionGuidePeak'),
        value: _px(peak),
      ),
      if (snr != null)
        MetricVm(
          label: const NightText('nightSessionGuideSnr'),
          value: nightFixed(snr, 0),
        ),
    ],
  );
});
