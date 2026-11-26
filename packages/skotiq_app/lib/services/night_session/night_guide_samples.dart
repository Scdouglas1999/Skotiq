// The night's guide steps, from the guider's GuideStep events, which carry
// PHD2's raw distances in guide-camera pixels. A step whose axis is not a
// finite number is dropped, not drawn at 0. The buffer holds the night;
// Tonight's guiding chart shows a window of it.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/bridge_events.dart' as sk_events;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import 'night_history_sync.dart';

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
    _ref.listen<String>(runtimeHostSessionProvider, (previous, next) {
      if (previous != null && previous != next) {
        state = const <NightGuideSample>[];
      }
    });
    _bind(_ref.read(backendProvider));
    _ref.listen<SkotiqBackend>(backendProvider, (_, next) => _bind(next));
    _ref.listen<AsyncValue<NightHistory?>>(
      hostNightHistoryProvider,
      (_, next) {
        final history = next.valueOrNull;
        // As the night's events: merged after the build that delivered it.
        if (history != null) {
          scheduleMicrotask(() {
            if (mounted) mergeHostHistory(history.guideSamples);
          });
        }
      },
      fireImmediately: true,
    );
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
      final sample = nightGuideSampleFrom(event);
      if (sample != null) add(sample);
    });
    previous?.cancel();
  }

  void add(NightGuideSample sample) {
    if (!sample.raPx.isFinite || !sample.decPx.isFinite) return;
    final current = state;
    // A step that is not newer than the last one is a replay or a late
    // history row. Merge it so it cannot land twice or after a newer step.
    if (current.isNotEmpty && !sample.t.isAfter(current.last.t)) {
      mergeHostHistory([sample]);
      return;
    }
    final cutoff = sample.t.subtract(retention);
    var start = 0;
    while (start < current.length && current[start].t.isBefore(cutoff)) {
      start++;
    }
    start = math.max(start, current.length + 1 - maxSamples);
    state = <NightGuideSample>[...current.skip(start), sample];
  }

  /// Merge a host list with samples already received. The same millisecond
  /// and both residuals are one step. A live step newer than a late response
  /// stays. The oldest samples past [retention] or [maxSamples] are dropped.
  void mergeHostHistory(List<NightGuideSample> samples) {
    if (!mounted) return;
    final bySample = <String, NightGuideSample>{};
    String key(NightGuideSample sample) => '${sample.t.millisecondsSinceEpoch}|'
        '${sample.raPx.toStringAsFixed(6)}|'
        '${sample.decPx.toStringAsFixed(6)}';
    for (final sample in [...samples, ...state]) {
      if (!sample.raPx.isFinite || !sample.decPx.isFinite) continue;
      // Six decimals: the wire's doubles, so 0.3 * 3 and 0.9 are one step
      // and two residuals that actually differ are not.
      bySample[key(sample)] = sample;
    }
    if (bySample.isEmpty) return;
    final merged = bySample.values.toList()..sort((a, b) => a.t.compareTo(b.t));
    final cutoff = merged.last.t.subtract(retention);
    final retained = <NightGuideSample>[
      for (final sample in merged)
        if (!sample.t.isBefore(cutoff)) sample,
    ];
    state = retained.length > maxSamples
        ? retained.sublist(retained.length - maxSamples)
        : retained;
  }

  @override
  void dispose() {
    _generation++;
    _sub?.cancel();
    super.dispose();
  }
}

/// The sample a guide step carries, or null for any other event and for a
/// step whose axes are not finite numbers. Such a step is dropped, not drawn
/// at 0.
NightGuideSample? nightGuideSampleFrom(SkotiqEvent event) {
  final payload = typedEventFromWire(event)?.payload;
  if (payload is! sk_events.EventPayload_Guiding) return null;
  final step = payload.field0;
  if (step is! sk_events.GuidingEvent_Correction) return null;
  final ra = step.raRaw;
  final dec = step.decRaw;
  if (!ra.isFinite || !dec.isFinite) return null;
  final t = event.timestamp > 0
      ? DateTime.fromMillisecondsSinceEpoch(event.timestamp)
      : DateTime.now();
  return NightGuideSample(t, ra, dec);
}
