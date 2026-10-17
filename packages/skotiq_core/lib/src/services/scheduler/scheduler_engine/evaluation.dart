part of '../scheduler_engine.dart';

extension _SchedulerEngineEvaluation on SchedulerEngine {
  void _restartTimer() {
    _tickTimer?.cancel();
    _tickTimer = Timer.periodic(_config.tickInterval, (_) {
      _updateStatus(
        _status.copyWith(nextEvaluationAt: _clock().add(_config.tickInterval)),
      );
      _evaluateWithReason('tick');
    });
  }

  Future<void> _evaluateWithReason(
    String reason, {
    List<SchedulerCandidate>? candidates,
  }) async {
    if (_evaluating) {
      // Queue this caller; they'll be released after the in-flight
      // evaluation finishes. This serializes evaluations without dropping
      // a triggering event.
      final c = Completer<void>();
      _pendingEvaluations.add(c);
      return c.future;
    }
    _evaluating = true;
    // Published so stop() can wait for a dispatch that is already in flight
    // rather than racing it (see SchedulerEngine._awaitEvaluationQuiescence).
    final idle = Completer<void>();
    _evaluationIdle = idle;
    try {
      await _evaluateOnce(reason, candidates: candidates);
    } finally {
      _evaluating = false;
      if (identical(_evaluationIdle, idle)) _evaluationIdle = null;
      if (!idle.isCompleted) idle.complete();
      if (_pendingEvaluations.isNotEmpty) {
        final next = _pendingEvaluations.removeAt(0);
        // Run the next evaluation in a microtask so the completer for the
        // current caller resolves first.
        scheduleMicrotask(() async {
          try {
            await _evaluateWithReason('coalesced');
            next.complete();
          } catch (e, st) {
            next.completeError(e, st);
          }
        });
      }
    }
  }

  Future<void> _evaluateOnce(
    String reason, {
    List<SchedulerCandidate>? candidates,
  }) async {
    final now = _clock();
    final loadedCandidates = candidates ?? await _candidateLoader();

    // Ask the executor whether the run we dispatched is still ours BEFORE
    // scoring against `_status.currentTargetId` — that field is the last thing
    // dispatched, not an ownership token, and hysteresis reads it. A run that
    // ended by any path the engine never hears about (failure, abort, operator
    // Stop) otherwise pins it forever and no later tick ever dispatches again.
    // Safe against the dispatch itself: evaluations are serialized by the
    // in-flight lock, so this can never run between `dispatchSequence` being
    // called and the executor starting the run.
    if (_status.state == SchedulerState.running) {
      _reconcileDispatchedRun(reason);
    }

    // Pure, side-effect-free evaluation against the engine's CURRENT
    // hysteresis state (_status.currentTargetId). This computes the exact
    // decision the autopilot will act on; the side effects (publishing the
    // decision, mutating _status, dispatching/parking) live below so the
    // read-only preview path (previewDecision/previewRanking) can reuse the
    // same _evaluate without ever touching them.
    final outcome = _evaluate(
      candidates: loadedCandidates,
      now: now,
      currentTargetId: _status.currentTargetId,
      reason: reason,
    );

    // Re-evaluating while idle or paused is a read-only operator preview:
    // mutating currentTargetId here would make a later Start see
    // isSwitch=false and skip dispatch, or claim a target switch the sequencer
    // never performed.
    if (_status.state != SchedulerState.running) {
      _publishDecision(outcome.decision);
      return;
    }

    if (outcome.winner == null) {
      // The empty path can stop imaging, so its decision is published AFTER the
      // side effect, carrying the sentence that explains it. `finally` so a
      // throwing park/stop still publishes the tick the operator is watching.
      String? note;
      try {
        note = await _handleNoEligibleTarget(now);
      } finally {
        _publishDecision(
          note == null
              ? outcome.decision
              : _withReasoning(outcome.decision, note),
        );
      }
      return;
    }

    _publishDecision(outcome.decision);

    if (outcome.isSwitch) {
      final winner = outcome.winner!;
      if (_status.state == SchedulerState.running) {
        final chosenCandidate = loadedCandidates.firstWhere(
          (c) => c.targetId == winner.targetId,
        );
        final seq = buildSequenceForCandidate(chosenCandidate);
        // Commit the winner into status ONLY after dispatch succeeds. If we
        // committed first and dispatch then threw (a transient pre-flight
        // failure: brief disk dip, momentarily disconnected filter wheel,
        // native start hiccup), the next tick would see
        // currentTargetId == winner and hysteresis would make isSwitch=false,
        // so the engine would never re-dispatch — the autopilot would believe
        // it is imaging a target that never started. By dispatching first and
        // rolling the status back on failure, the next tick retries the switch.
        // Record the run BEFORE handing it over: the executor may be starting
        // while the operator presses Stop, and a stop that arrives in that
        // window still has to be able to name (and end) the run this dispatch
        // is creating. The generation snapshot below is how the post-await
        // commit learns such a stop happened.
        final generation = _runGeneration;
        _dispatchedRunId = seq.id;
        try {
          await _sequenceSink.dispatchSequence(seq);
        } catch (e) {
          // Leave currentTargetId unchanged (it is NOT the failed winner) so
          // the next evaluation re-attempts the switch. Surface the failure on
          // the status panel and hand the editor slot back to the operator so
          // their stashed manual sequence is not orphaned behind a wedged
          // autopilot.
          _updateStatus(
            _status.copyWith(
              lastError: 'Failed to start ${winner.targetName}: $e',
            ),
          );
          await _sequenceSink.releaseSequenceOwnership();
          return;
        }
        if (_runGeneration != generation ||
            _status.state != SchedulerState.running) {
          // The autopilot was disengaged while the executor was starting. The
          // run that just began is not ours to claim — stop() waited for this
          // dispatch precisely so it can end it — and an idle engine must never
          // report that it owns a target.
          return;
        }
        _updateStatus(
          _status.copyWith(
            currentTargetId: winner.targetId,
            currentTargetName: winner.targetName,
            clearError: true,
          ),
        );
        // A target was dispatched: a (new) observing night is under way, so
        // re-arm the end-of-night park for the next dawn.
        _parkedForEndOfNight = false;
        _dispatchedSinceStart = true;
      }
    }
  }

  /// Pure, side-effect-free core of an evaluation: score every candidate,
  /// apply the SAME hard gates the autopilot applies (via [_scoreCandidate]:
  /// twilight Sun gate, min altitude, custom horizon, filter availability,
  /// time-window, moon), apply the scheduled-window override and hysteresis
  /// against [currentTargetId], and build the resulting [SchedulerDecision].
  ///
  /// This NEVER mutates `_status`, NEVER dispatches, and NEVER parks — those
  /// effects are applied by [_evaluateOnce] using the returned outcome. The
  /// read-only [previewDecision]/[previewRanking] reuse this verbatim so the
  /// human-facing preview is the autopilot's decision by construction.
  _EvaluationOutcome _evaluate({
    required List<SchedulerCandidate> candidates,
    required DateTime now,
    required int? currentTargetId,
    required String reason,
  }) {
    if (candidates.isEmpty) {
      return _EvaluationOutcome(
        decision: SchedulerDecision(
          chosenTargetId: null,
          chosenTargetName: null,
          score: 0,
          reasoning: const ['No candidate targets available'],
          scoredCandidates: const [],
          rejected: const [],
          evaluatedAt: now,
          isSwitch: currentTargetId != null,
        ),
        winner: null,
        isSwitch: false,
      );
    }

    final scored = <TargetScore>[];
    // Tracks which candidates fall inside an active scheduledWindow at
    // this tick. The first such target (preferring the higher base score
    // when multiple overlap) wins regardless of hysteresis.
    final scheduledWindowHits = <int>{};
    for (final c in candidates) {
      scored.add(_scoreCandidate(c, now));
      if (_hasActiveScheduledWindow(c, now)) {
        scheduledWindowHits.add(c.targetId);
      }
    }

    final eligible = scored.where((s) => !s.hardConstraintFailed).toList();
    eligible.sort((a, b) => b.totalScore.compareTo(a.totalScore));

    if (eligible.isEmpty) {
      final reasons = <String>[
        'No eligible candidates at ${now.toIso8601String()} ($reason)',
        ...scored
            .where((s) => s.rejectionReasons.isNotEmpty)
            .take(3)
            .map((s) => '${s.targetName}: ${s.rejectionReasons.first}'),
      ];
      final rejectedAll = scored
          .map(
            (s) => _buildRejection(
              s,
              chosenScore: 0,
              primaryReasonOverride: s.hardConstraintFailed
                  ? null
                  : 'no eligible winner',
            ),
          )
          .toList();
      return _EvaluationOutcome(
        decision: SchedulerDecision(
          chosenTargetId: null,
          chosenTargetName: null,
          score: 0,
          reasoning: reasons,
          scoredCandidates: scored,
          rejected: rejectedAll,
          evaluatedAt: now,
          isSwitch: currentTargetId != null,
        ),
        winner: null,
        isSwitch: false,
      );
    }

    final challenger = eligible.first;
    final currentId = currentTargetId;
    TargetScore winner;
    bool isSwitch;
    // True when the chosen target was forced by an active scheduled
    // window — the UI labels this distinctly ("Forced by scheduled
    // window …") and we skip hysteresis.
    bool forcedByScheduledWindow = false;

    // Scheduled-window override path: any eligible candidate that has an
    // active scheduledWindow constraint MUST be selected, bypassing
    // hysteresis. When multiple targets are inside their windows at the
    // same instant, the higher base score (already applied in scoring)
    // wins — eligible[0] is sorted by totalScore so the first eligible
    // entry whose id is in scheduledWindowHits is the right pick.
    TargetScore? forced;
    for (final s in eligible) {
      if (scheduledWindowHits.contains(s.targetId)) {
        forced = s;
        break;
      }
    }

    if (forced != null) {
      winner = forced;
      isSwitch = currentId != forced.targetId;
      forcedByScheduledWindow = true;
    } else if (currentId == null) {
      winner = challenger;
      isSwitch = true;
    } else {
      final currentEntry = eligible
          .where((s) => s.targetId == currentId)
          .toList();
      if (currentEntry.isEmpty) {
        // Current target is no longer eligible: forced switch.
        winner = challenger;
        isSwitch = true;
      } else {
        final current = currentEntry.first;
        final ratio = current.totalScore > 0
            ? challenger.totalScore / current.totalScore
            : double.infinity;
        if (challenger.targetId == current.targetId) {
          winner = current;
          isSwitch = false;
        } else if (ratio >= _config.hysteresisRatio) {
          winner = challenger;
          isSwitch = true;
        } else {
          winner = current;
          isSwitch = false;
        }
      }
    }

    final reasoning = <String>[];
    reasoning.add(
      'Chose ${winner.targetName} (score ${winner.totalScore.toStringAsFixed(3)}) at ${now.toIso8601String()} ($reason)',
    );
    for (final f in winner.factors) {
      reasoning.add(
        '  ${f.name}: value=${f.value.toStringAsFixed(3)} weight=${f.weight.toStringAsFixed(2)} -> ${f.weighted.toStringAsFixed(3)}${f.detail != null ? "  ${f.detail}" : ""}',
      );
    }
    if (forcedByScheduledWindow) {
      reasoning.add(
        'Forced by scheduled window (hysteresis bypassed) on ${winner.targetName}',
      );
    }
    if (eligible.length > 1) {
      final next = eligible.firstWhere(
        (s) => s.targetId != winner.targetId,
        orElse: () => eligible[1],
      );
      reasoning.add(
        'Runner-up: ${next.targetName} score ${next.totalScore.toStringAsFixed(3)}',
      );
    }
    if (isSwitch && currentId != null && !forcedByScheduledWindow) {
      reasoning.add(
        'Switching from previous target id=$currentId (hysteresis ratio=${_config.hysteresisRatio.toStringAsFixed(2)} exceeded)',
      );
    }

    final orderedAll = [
      ...eligible,
      ...scored.where((s) => s.hardConstraintFailed),
    ];

    final rejected = <RejectedCandidate>[];
    for (final s in orderedAll) {
      if (s.targetId == winner.targetId) continue;
      rejected.add(_buildRejection(s, chosenScore: winner.totalScore));
    }

    return _EvaluationOutcome(
      decision: SchedulerDecision(
        chosenTargetId: winner.targetId,
        chosenTargetName: winner.targetName,
        score: winner.totalScore,
        reasoning: reasoning,
        scoredCandidates: orderedAll,
        rejected: rejected,
        evaluatedAt: now,
        isSwitch: isSwitch,
      ),
      winner: winner,
      isSwitch: isSwitch,
    );
  }

  /// True when the Sun has risen above the configured darkness limit at
  /// [now] — i.e. the observing night is over. This reuses the exact gate the
  /// per-candidate twilight check applies in [_scoreCandidate], so "every
  /// candidate Sun-rejected" and "end of night" are the same condition by
  /// construction. A transient empty-eligible at night (clouds rejecting a
  /// weather constraint, every goal momentarily complete) is NOT end-of-night
  /// because the Sun is still down, so this returns false and the engine only
  /// stops the sequence rather than parking.
  bool _isEndOfNight(DateTime now) {
    final (sunAlt, _) = SkyCalculations.sunAltAz(
      time: now,
      latitudeDegrees: _site.latitudeDegrees,
      longitudeDegrees: _site.longitudeDegrees,
    );
    return sunAlt > _config.maxSunAltitudeDegrees;
  }

  /// Shared handling for both empty paths in [_evaluateOnce] (no candidates at
  /// all, and candidates present but none eligible). Clears the current target,
  /// stops the sequence the autopilot itself dispatched, and — only when it is
  /// genuinely end-of-night (Sun up) and we have not already parked for this
  /// dawn — invokes the distinct end-of-night park hook exactly once.
  ///
  /// Returns the operator-facing sentence to append to this tick's reasoning
  /// when imaging was stopped, or null when the tick changed nothing.
  Future<String?> _handleNoEligibleTarget(DateTime now) async {
    final running = _status.state == SchedulerState.running;
    // Whether the autopilot has a run of its OWN in progress. It shares one
    // executor with the manual Start button, so a tick that stopped
    // unconditionally would kill a sequence the operator started by hand,
    // mid-exposure, every 60 s, all night.
    final ownedTarget = _status.currentTargetName;
    // Ownership is decided by the run the autopilot dispatched still being the
    // executor's active run — asked of the sink, which can see the executor —
    // not by the engine's own `currentTargetId`. That field only says "the
    // last thing I dispatched"; it survives an operator Stop, an abort, and a
    // failed run, because only a natural completion reaches the engine's
    // trigger stream. Testing it stopped the operator's manual sequence.
    final runId = _dispatchedRunId;
    final ownsRun = runId != null && _ownsDispatchedRun(runId);
    if (_status.currentTargetId != null) {
      _updateStatus(_status.copyWith(clearCurrentTarget: true));
    }
    if (!ownsRun) _dispatchedRunId = null;
    if (!running) return null;

    if (_isEndOfNight(now)) {
      // Starting the autopilot before sunset is an ordinary pre-arm workflow.
      // Until this run has actually dispatched a target there is no completed
      // observing night to safe, so wait quietly for a later eligible tick.
      if (!_dispatchedSinceStart) return null;
      // Dawn: park the mount so it stops tracking into the ground/daylight.
      // Guarded so we park once per dawn, not on every subsequent tick while
      // the Sun stays up. Park first (the safety-critical action), then the
      // stopSequence below is redundant on the park path but harmless — the
      // executor is idempotent on stop and parkForEndOfNight already pauses.
      if (!_parkedForEndOfNight) {
        // The THIRD engine-initiated teardown. parkForEndOfNight routes to
        // SafeRigService.safeTheRig(park: true), which PAUSES the running
        // sequence before parking — so an unowned dawn park would end the
        // operator's exposure mid-frame with no ownership check and no warning,
        // the same reasoning that gates the other two. Parking an idle rig at
        // sunrise is still right (the mount may be tracking into the ground),
        // so the gate is "somebody else is running", not "not mine".
        if (!ownsRun && _executorHasActiveRun()) {
          // WARNING: the night ended without a park.
          _log(
            SchedulerLogLevel.warning,
            'Scheduler dawn park declined: the active run is not the one the '
            'autopilot dispatched — leaving the rig to its owner',
          );
          return 'Dawn has arrived but the autopilot is not parking: the run on '
              'the rig is not the one it started. Stop that run to have the '
              'mount parked.';
        }
        _parkedForEndOfNight = true;
        _dispatchedRunId = null;
        await _sequenceSink.parkForEndOfNight();
        return 'The observing night is over — parked the mount and ended '
            'unattended imaging.';
      }
      return null;
    }

    // Transient no-eligible mid-night (clouds, all goals momentarily
    // complete): stop the autopilot's OWN sequence but never park — the night
    // isn't over and the next tick may re-dispatch. A run the operator started
    // by hand is not ours to end.
    if (!ownsRun) return null;
    _dispatchedRunId = null;
    await _sequenceSink.stopSequence();
    return 'Stopped ${ownedTarget ?? 'imaging'} — no target passes the '
        'scheduler right now; the next evaluation will re-check.';
  }

  /// [decision] with one more line on its reasoning list — how a side effect
  /// the pure [_evaluate] cannot know about (stopping imaging, parking at
  /// dawn) reaches the operator, since the decision panel renders `reasoning`
  /// and nothing else explains itself.
  SchedulerDecision _withReasoning(SchedulerDecision decision, String line) {
    return SchedulerDecision(
      chosenTargetId: decision.chosenTargetId,
      chosenTargetName: decision.chosenTargetName,
      score: decision.score,
      reasoning: [...decision.reasoning, line],
      scoredCandidates: decision.scoredCandidates,
      rejected: decision.rejected,
      evaluatedAt: decision.evaluatedAt,
      isSwitch: decision.isSwitch,
    );
  }

  /// Returns true if the candidate has an enabled scheduledWindow
  /// constraint whose absolute UTC range contains [now]. Caller uses this
  /// to bypass hysteresis and to surface the forced-selection state on
  /// the decision panel.
  bool _hasActiveScheduledWindow(SchedulerCandidate c, DateTime now) {
    for (final ct in c.constraints.where((x) => x.enabled)) {
      if (ct.kind != TargetConstraintKind.scheduledWindow) continue;
      final sw = ct.scheduledWindow;
      if (sw == null) continue;
      if (sw.containsUtc(now)) return true;
    }
    return false;
  }

  /// Build a [RejectedCandidate] entry that the UI will render under the
  /// "Other candidates considered" section. The reason text is derived
  /// from the same hard-constraint / soft-score logic that filtered them
  /// out of [_scoreCandidate].
  RejectedCandidate _buildRejection(
    TargetScore s, {
    required double chosenScore,
    String? primaryReasonOverride,
  }) {
    final String primary;
    if (primaryReasonOverride != null) {
      primary = primaryReasonOverride;
    } else if (s.hardConstraintFailed) {
      primary = _summarizeRejection(s.rejectionReasons);
    } else {
      // Eligible-but-lower-scoring. Expose the score gap as a percentage
      // so operators can sanity-check tight calls.
      if (chosenScore > 0) {
        final pct = (s.totalScore / chosenScore * 100).clamp(0, 999);
        primary =
            'lower score than chosen (${pct.toStringAsFixed(0)}% of winner)';
      } else {
        primary = 'lower score than chosen';
      }
    }
    return RejectedCandidate(
      targetId: s.targetId,
      targetName: s.targetName,
      score: s.totalScore,
      primaryReason: primary,
      hardConstraintFailures: List<String>.unmodifiable(s.rejectionReasons),
      factors: List<ScoreFactor>.unmodifiable(s.factors),
    );
  }

  /// Map the first per-constraint failure into a compact operator-facing
  /// summary. Falls back to the raw text when no shorter form fits.
  ///
  /// The matching ladder lives in `services/scheduler/rejection_labels.dart`
  /// so the queue row's STATUS chip and this record cannot drift apart. Do NOT
  /// re-add a local ladder here — `scheduler_rejection_labels_test.dart` covers
  /// both renderings.
  String _summarizeRejection(List<String> reasons) {
    if (reasons.isEmpty) return 'rejected';
    return schedulerRejectionSummary(
      reasons.first,
      minAltitudeDegrees: _config.minAltitudeDegrees,
    );
  }

  void _updateStatus(SchedulerStatus next) {
    _status = next;
    if (!_statusController.isClosed) {
      _statusController.add(next);
    }
  }

  void _publishDecision(SchedulerDecision decision) {
    _lastDecision = decision;
    if (!_decisionController.isClosed) {
      _decisionController.add(decision);
    }
  }
}
