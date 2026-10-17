// What the phone is told when a run stops.
//
// A stop reaches the phone only when the operator did NOT press it — a safety
// abort, the autopilot's re-plan, a subsystem stop — at INFO (non-alarm)
// priority, carrying the real cause. The operator's own press stays silent:
// they are standing at the keyboard that issued it, and a phone that buzzes for
// every deliberate Stop trains them to ignore it.
//
// Deciding that needs the EPISODE, not the event. One stop publishes several
// events — the cancel-notice Error, the cancel-notice lifecycle decision, the
// authorship decision, and the terminal `Stopped` pair, the last of which the
// stop API publishes only after the whole safing teardown — and the one that
// names the author can arrive AFTER the ones that do not (the stop API sends
// the executor command before recording its decision, and that send yields).
// So the push waits a short grace for the author before it claims anything,
// and every later member of the same episode is silent: one stop, one push.

import 'dart:async';

import '../../providers/sequence/run_stop_classification.dart';

/// One stop episode: everything published by a single stop of a single run.
class _StopEpisode {
  /// The run this episode belongs to, when the wire carried it. Two episodes
  /// with DIFFERENT run ids are never the same stop, however close in time.
  int? runId;

  SequenceStopDecision? decision;

  /// The context of the most recent member, so the deferred push renders the
  /// operator's own templates with the same values the immediate surfaces saw.
  Map<String, String> values = const {};

  /// When the most recent member of this episode arrived.
  DateTime lastSeen;

  /// Set once the phone push has been decided (fired or deliberately
  /// withheld), so the trailing members cannot page a second time.
  bool pushSettled = false;

  /// Set once the immediate surfaces (toast, external alerts) have announced
  /// this stop, so the members that follow cannot say it again.
  bool announced = false;

  Timer? graceTimer;

  _StopEpisode(this.lastSeen, this.runId);
}

/// Collects the members of a stop episode and decides the single phone push.
class StopPushArbiter {
  /// How long to wait, after the first member of an episode, for the
  /// authorship decision. The stop's producers land within milliseconds of
  /// each other (they share one broadcast channel); this is generous enough
  /// to absorb the race in either direction and short enough that an
  /// unattended abort still reaches the phone while it matters.
  static const Duration authorGrace = Duration(seconds: 5);

  /// How far apart two members of ONE episode can plausibly land when the wire
  /// carries no run id: the api-published `Stopped` trails the press by the
  /// safing teardown (exposure abort + park + dome). Mirrors the Run
  /// Dashboard's stop-fold bound.
  static const Duration episodeSpan = Duration(minutes: 2);

  final DateTime Function() _now;

  /// Called at most once per episode, with the stop decision the wire proved
  /// (null for a safety abort nobody commanded) and the episode's context.
  /// Never called for an operator press.
  final void Function(
    SequenceStopDecision? decision,
    Map<String, String> values,
  )
  _onPush;

  _StopEpisode? _current;

  /// Every armed grace timer, including those of episodes that are no longer
  /// the open one — a run that stops while the previous stop's grace is still
  /// running must not swallow the previous push.
  final Set<Timer> _armed = {};

  StopPushArbiter({
    required DateTime Function() clock,
    required void Function(
      SequenceStopDecision? decision,
      Map<String, String> values,
    )
    onPush,
  }) : _now = clock,
       _onPush = onPush;

  /// Record who ended the run. Called for the executor's stop decisions, which
  /// raise no notification of their own.
  void noteDecision(SequenceStopDecision decision, {int? runId}) {
    final episode = _join(runId);
    // A human's press outranks whatever else claimed the stop: if the operator
    // pressed Stop on a run the autopilot was already ending, they know.
    if (episode.decision == null ||
        decision.author == SequenceStopAuthor.operatorPress) {
      episode.decision = decision;
    }
  }

  /// Record a routed stop notification and arm this episode's phone push.
  ///
  /// Returns the decision known RIGHT NOW plus whether this episode has
  /// already been announced. The immediate surfaces do NOT wait for the
  /// grace — the first member speaks, with whatever the wire has proved by
  /// then (degrading to the cause-neutral sentence rather than inventing an
  /// author), and the rest of the episode stays quiet, because one stop is one
  /// toast.
  ({SequenceStopDecision? decision, bool announced}) noteStopNotification({
    int? runId,
    Map<String, String> values = const {},
  }) {
    final episode = _join(runId);
    episode.values = values;
    if (!episode.pushSettled && episode.graceTimer == null) {
      final timer = Timer(authorGrace, () => _settle(episode));
      episode.graceTimer = timer;
      _armed.add(timer);
    }
    final announced = episode.announced;
    episode.announced = true;
    return (decision: episode.decision, announced: announced);
  }

  /// A new run has started: nothing published from here belongs to the
  /// previous run's stop.
  void noteRunBoundary() {
    _current = null;
  }

  void dispose() {
    for (final timer in _armed) {
      timer.cancel();
    }
    _armed.clear();
    _current = null;
  }

  void _settle(_StopEpisode episode) {
    final timer = episode.graceTimer;
    if (timer != null) _armed.remove(timer);
    episode.graceTimer = null;
    if (episode.pushSettled) return;
    episode.pushSettled = true;
    if (episode.decision?.author == SequenceStopAuthor.operatorPress) return;
    _onPush(episode.decision, episode.values);
  }

  /// The episode this member belongs to: the open one when both run ids are
  /// present and EQUAL (identity outranks time — the terminal `Stopped` can
  /// trail the press by however long the safing teardown takes, and a matching
  /// id is proof it is the same stop), or when one id is absent and the member
  /// landed inside [episodeSpan]; otherwise a new one.
  _StopEpisode _join(int? runId) {
    final now = _now();
    final current = _current;
    final idsAgree =
        runId != null && current?.runId != null && current!.runId == runId;
    if (current != null &&
        (idsAgree ||
            (!(runId != null &&
                    current.runId != null &&
                    current.runId != runId) &&
                now.difference(current.lastSeen).abs() <= episodeSpan))) {
      current.runId ??= runId;
      current.lastSeen = now;
      return current;
    }
    // The previous episode keeps its armed grace: a run that stops while the
    // last stop is still settling must not swallow that push.
    return _current = _StopEpisode(now, runId);
  }
}
