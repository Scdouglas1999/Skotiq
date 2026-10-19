// The session's event marks: autofocus runs, dithers, flips, lost stars.
//
// `eventHistoryProvider` keeps the last 100 events, and while guiding a
// GuideStep arrives every one to two seconds, so a mark from 21:40 is gone
// long before midnight. This notifier keeps only the few event kinds the
// session charts and the log mark, for the whole session, in memory. Nothing
// survives an app restart; the charts then start from the restart.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../night_control_contracts.dart';
import 'session_frames_provider.dart';

/// One finished autofocus run, as the log and the focus marks show it.
@immutable
class NightAutofocusRun {
  const NightAutofocusRun({
    required this.at,
    this.position,
    this.hfr,
    this.duration,
  });

  final DateTime at;
  final int? position;
  final double? hfr;
  final Duration? duration;
}

/// A dither the guider started, with its size when the event carried one.
@immutable
class NightDither {
  const NightDither({required this.at, this.pixels});

  final DateTime at;
  final double? pixels;
}

@immutable
class NightSessionEvents {
  const NightSessionEvents({
    this.autofocusRuns = const <NightAutofocusRun>[],
    this.dithers = const <NightDither>[],
    this.flips = const <DateTime>[],
    this.starLost = const <DateTime>[],
  });

  final List<NightAutofocusRun> autofocusRuns;
  final List<NightDither> dithers;
  final List<DateTime> flips;
  final List<DateTime> starLost;

  /// Autofocus, dither and flip marks, time ordered.
  List<SeriesMarker> get markers => <SeriesMarker>[
        for (final run in autofocusRuns)
          SeriesMarker(run.at, SeriesMarkerKind.autofocus),
        for (final dither in dithers)
          SeriesMarker(dither.at, SeriesMarkerKind.dither),
        for (final flip in flips) SeriesMarker(flip, SeriesMarkerKind.flip),
      ]..sort((a, b) => a.t.compareTo(b.t));
}

final nightSessionEventsProvider =
    StateNotifierProvider<NightSessionEventsNotifier, NightSessionEvents>(
  NightSessionEventsNotifier.new,
);

class NightSessionEventsNotifier extends StateNotifier<NightSessionEvents> {
  NightSessionEventsNotifier(this._ref) : super(const NightSessionEvents()) {
    _bind(_ref.read(backendProvider));
    _ref.listen<SkotiqBackend>(backendProvider, (_, next) => _bind(next));
    _ref.listen<int?>(nightSessionIdProvider, (previous, next) {
      // A new session starts its own marks; the end of one keeps them so
      // the charts still read after the run.
      if (next != null && previous != null && next != previous) {
        state = const NightSessionEvents();
      }
    });
    _ref.listen<AutofocusOverlayState>(
      autofocusOverlayProvider,
      _onAutofocusOverlay,
    );
    _ref.listen<SequenceRunStats?>(
      liveSequenceStatsProvider,
      _onRunStats,
    );
  }

  final Ref _ref;
  StreamSubscription<SkotiqEvent>? _sub;
  int _generation = 0;
  DateTime? _autofocusStartedAt;

  /// Each list keeps at most this many entries, oldest dropped first.
  static const int maxPerKind = 500;

  /// A run counted by the sequencer within this window of one the overlay
  /// reported is the same run.
  static const Duration sameAutofocusWindow = Duration(minutes: 2);

  void _bind(SkotiqBackend backend) {
    final generation = ++_generation;
    final previous = _sub;
    _sub = backend.eventStream.listen((event) {
      if (generation != _generation || !mounted) return;
      _onEvent(event);
    });
    previous?.cancel();
  }

  static DateTime _timeOf(SkotiqEvent event) => event.timestamp > 0
      ? DateTime.fromMillisecondsSinceEpoch(event.timestamp)
      : DateTime.now();

  static List<T> _capped<T>(List<T> list) =>
      list.length <= maxPerKind ? list : list.sublist(list.length - maxPerKind);

  void _onEvent(SkotiqEvent event) {
    final at = _timeOf(event);
    if (event.category == EventCategory.guiding) {
      switch (event.eventType) {
        case 'DitherStarted':
          final pixels = (event.data['pixels'] as num?)?.toDouble();
          state = NightSessionEvents(
            autofocusRuns: state.autofocusRuns,
            dithers: _capped(
              [...state.dithers, NightDither(at: at, pixels: pixels)],
            ),
            flips: state.flips,
            starLost: state.starLost,
          );
        case 'StarLost':
          state = NightSessionEvents(
            autofocusRuns: state.autofocusRuns,
            dithers: state.dithers,
            flips: state.flips,
            starLost: _capped([...state.starLost, at]),
          );
      }
      return;
    }
    if (event.category == EventCategory.sequencer &&
        event.eventType == 'MeridianFlipOutcome' &&
        event.data['outcome'] == 'success') {
      state = NightSessionEvents(
        autofocusRuns: state.autofocusRuns,
        dithers: state.dithers,
        flips: _capped([...state.flips, at]),
        starLost: state.starLost,
      );
    }
  }

  void _onAutofocusOverlay(
    AutofocusOverlayState? previous,
    AutofocusOverlayState next,
  ) {
    if (next.isRunning && previous?.isRunning != true) {
      _autofocusStartedAt = DateTime.now();
      return;
    }
    if (previous?.isRunning != true || next.isRunning) return;
    final result = next.result;
    final startedAt = _autofocusStartedAt;
    _autofocusStartedAt = null;
    // A failed or cancelled run moved nothing worth marking.
    if (next.hasError || result == null) return;
    final now = DateTime.now();
    _addAutofocus(
      NightAutofocusRun(
        at: now,
        position: result.bestPosition,
        hfr: result.bestHfr,
        duration: startedAt == null ? null : now.difference(startedAt),
      ),
    );
  }

  void _onRunStats(SequenceRunStats? previous, SequenceRunStats? next) {
    if (previous == null || next == null) return;
    if (next.autofocusRuns <= previous.autofocusRuns) return;
    final now = DateTime.now();
    final last = state.autofocusRuns.isEmpty ? null : state.autofocusRuns.last;
    // The overlay usually reported this run a moment ago with its result.
    if (last != null && now.difference(last.at).abs() <= sameAutofocusWindow) {
      return;
    }
    _addAutofocus(NightAutofocusRun(at: now));
  }

  void _addAutofocus(NightAutofocusRun run) {
    final runs = [...state.autofocusRuns];
    final last = runs.isEmpty ? null : runs.last;
    // The sequencer's count can land first; the overlay's result for the
    // same run then fills that bare mark in instead of adding a second.
    if (last != null &&
        last.position == null &&
        run.position != null &&
        run.at.difference(last.at).abs() <= sameAutofocusWindow) {
      runs.removeLast();
    }
    state = NightSessionEvents(
      autofocusRuns: _capped([...runs, run]),
      dithers: state.dithers,
      flips: state.flips,
      starLost: state.starLost,
    );
  }

  @override
  void dispose() {
    _generation++;
    _sub?.cancel();
    super.dispose();
  }
}
