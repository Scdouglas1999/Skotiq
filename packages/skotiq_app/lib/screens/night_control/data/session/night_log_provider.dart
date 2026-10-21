// Overview's "Log": the night in one list, newest first.
//
// Three sources, merged by time:
//  * the run feed: device, guider, safety and sequencer events, folded and
//    named the way the Sequencer's trigger feed shows them;
//  * the session's frames from captured_images, which carry the frame
//    number, the filter, the verdict and the HFR the feed's "Frame accepted"
//    row does not;
//  * the autofocus results this app saw finish, with position and HFR.
// The feed's per-frame and telemetry rows are dropped: the frame rows above
// say the same thing with more, and guide corrections or progress ticks
// would push every other line out of the list.
//
// The feed is recorded here as it arrives rather than read from
// `eventHistoryProvider`, which keeps only the last 100 events of every kind.
// While a frame exposes the camera reports its progress five times a second
// and the guider reports every step, so that history turns over in well under
// a minute: read straight from it, a dither or a guiding row vanished from the
// log a few seconds after it happened while the older autofocus and frame
// rows, which come from longer-lived sources, stayed.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:skotiq_core/skotiq_core.dart' show eventHistoryProvider;
import 'package:skotiq_core/skotiq_core_events.dart' as sk_events;

import '../../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart'
    show RunDashboardEvent, RunDashboardEventSeverity, runDashboardFeedRows;
import '../../night_control_contracts.dart';
import 'session_events_provider.dart';
import 'session_format.dart';
import 'session_frames_provider.dart';

/// How many feed events the log keeps, oldest dropped first.
const int kNightLogFeedLimit = 400;

/// How many lines the log keeps, oldest dropped first.
const int kNightLogMaxEntries = 200;

/// Feed rows the log leaves out, by the title the shared event display
/// helper gives them: per-frame rows the session rows replace, and
/// telemetry that is not an event of the night.
const Set<String> _feedTitlesLeftOut = <String>{
  'Frame accepted',
  'Frame rejected',
  'Exposure complete',
  'Exposure progress',
  'Progress',
  'Instruction progress',
  'Camera temperature',
  'Guiding correction',
  'Guide stats',
  'PHD2 state',
};

bool nightLogKeepsFeedRow(RunDashboardEvent event) =>
    !_feedTitlesLeftOut.contains(event.title);

/// The feed events the log keeps, newest first, recorded as they reach
/// `eventHistoryProvider` and held after that history has moved on.
final nightLogFeedEventsProvider =
    NotifierProvider<NightLogFeedRecorder, List<sk_events.SkotiqEvent>>(
  NightLogFeedRecorder.new,
);

class NightLogFeedRecorder extends Notifier<List<sk_events.SkotiqEvent>> {
  @override
  List<sk_events.SkotiqEvent> build() {
    ref.listen<List<sk_events.SkotiqEvent>>(
      eventHistoryProvider,
      (previous, next) => _record(previous ?? const [], next),
    );
    return _kept(ref.read(eventHistoryProvider)).toList(growable: false);
  }

  static Iterable<sk_events.SkotiqEvent> _kept(
    Iterable<sk_events.SkotiqEvent> events,
  ) =>
      events.where(
        (event) => !_feedTitlesLeftOut
            .contains(sk_events.skotiqEventDisplayTitle(event)),
      );

  /// The history only ever gains events at its front; the ones not in
  /// [previous] are new. By identity: the history holds each event once.
  void _record(
    List<sk_events.SkotiqEvent> previous,
    List<sk_events.SkotiqEvent> next,
  ) {
    final seen = Set<sk_events.SkotiqEvent>.identity()..addAll(previous);
    final fresh = _kept(next.takeWhile((event) => !seen.contains(event)));
    if (fresh.isEmpty) return;
    final merged = <sk_events.SkotiqEvent>[...fresh, ...state];
    state = merged.length > kNightLogFeedLimit
        ? merged.sublist(0, kNightLogFeedLimit)
        : merged;
  }
}

MetricTone _toneOf(RunDashboardEventSeverity severity) => switch (severity) {
      RunDashboardEventSeverity.critical ||
      RunDashboardEventSeverity.error =>
        MetricTone.bad,
      RunDashboardEventSeverity.warning => MetricTone.warning,
      RunDashboardEventSeverity.info => MetricTone.neutral,
    };

String _feedLine(RunDashboardEvent event) {
  final base =
      event.message.isEmpty ? event.title : '${event.title} · ${event.message}';
  return event.repeatCount > 1 ? '$base ×${event.repeatCount}' : base;
}

final nightLogProvider = Provider<List<NightLogEntryVm>>((ref) {
  final feed = runDashboardFeedRows(ref.watch(nightLogFeedEventsProvider));
  final lights = ref.watch(nightSessionLightRowsProvider);
  final autofocus = ref.watch(
    nightSessionEventsProvider.select((events) => events.autofocusRuns),
  );

  final entries = <NightLogEntryVm>[
    for (final event in feed)
      if (nightLogKeepsFeedRow(event))
        NightLogEntryVm(
          at: event.time,
          message: NightText.literal(_feedLine(event)),
          tone: _toneOf(event.severity),
        ),
  ];

  final firstFrame = lights.length > kNightLogMaxEntries
      ? lights.length - kNightLogMaxEntries
      : 0;
  for (var i = firstFrame; i < lights.length; i++) {
    final row = lights[i];
    final filter = row.filter;
    final hfr = row.hfr;
    final rejected = !row.isAccepted;
    final reason = row.rejectionReason;
    entries.add(
      NightLogEntryVm(
        at: row.capturedAt,
        message: NightText(
          rejected ? 'nightSessionLogFrameRejected' : 'nightSessionLogFrame',
          params: <String, String>{
            'n': '${i + 1}',
            'filter': filter == null || filter.isEmpty ? '' : ' $filter',
            'hfr': hfr == null ? '' : ' · HFR ${nightFixed(hfr, 2)}',
            'reason': rejected && reason != null && reason.isNotEmpty
                ? ' ($reason)'
                : '',
          },
        ),
        tone: rejected ? MetricTone.bad : MetricTone.neutral,
      ),
    );
  }

  for (final run in autofocus) {
    final position = run.position;
    final hfr = run.hfr;
    final duration = nightDuration(run.duration?.inSeconds.toDouble());
    entries.add(
      NightLogEntryVm(
        at: run.at,
        message: position == null
            ? const NightText('nightSessionLogAutofocusDone')
            : NightText(
                'nightSessionLogAutofocus',
                params: <String, String>{
                  'position': nightGrouped(position),
                  'hfr': hfr == null ? '' : ' · HFR ${nightFixed(hfr, 2)}',
                  'duration': duration == null ? '' : ' · $duration',
                },
              ),
      ),
    );
  }

  // Newest first; past the cap the oldest lines go.
  entries.sort((a, b) => b.at.compareTo(a.at));
  return entries.length > kNightLogMaxEntries
      ? entries.sublist(0, kNightLogMaxEntries)
      : entries;
});
