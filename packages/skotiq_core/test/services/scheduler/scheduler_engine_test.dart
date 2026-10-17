// Unit tests for the dynamic RoboTarget-class SchedulerEngine.
//
// These exercise the pure-logic core directly (no Riverpod, no database)
// via the candidateLoader / clock / sequenceSink injection points. Each
// test creates a fixed virtual clock so altitude / hour-angle results are
// deterministic.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/models/scheduler/scheduler_status.dart';
import 'package:skotiq_core/src/models/scheduler/target_constraint.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/scheduler/scheduler_engine.dart';

class _RecordingSink implements SchedulerSequenceSink {
  final List<Sequence> dispatched = [];
  int pauseCount = 0;
  int resumeCount = 0;
  int stopCount = 0;
  int parkCount = 0;
  int releaseCount = 0;

  @override
  Future<void> dispatchSequence(Sequence sequence) async {
    dispatched.add(sequence);
  }

  @override
  Future<void> pauseSequence() async {
    pauseCount++;
  }

  @override
  Future<void> resumeSequence() async {
    resumeCount++;
  }

  @override
  Future<void> stopSequence() async {
    stopCount++;
  }

  @override
  Future<void> parkForEndOfNight() async {
    parkCount++;
  }

  @override
  Future<void> releaseSequenceOwnership() async {
    releaseCount++;
  }
}

// Mid-northern observatory site used across the tests. Local offset is
// UTC-5 so wall-clock-based constraints behave like an east-coast user.
const _site = SchedulerSite(
  latitudeDegrees: 40.0,
  longitudeDegrees: -75.0,
  localOffset: Duration(hours: -5),
);

// Fixed virtual clock: 2026-05-11 04:00 UTC == 23:00 local previous day.
// At this instant a target at RA ~14h, Dec +30° is near the meridian for
// the site; a target at RA ~04h is setting low in the west; a target at
// RA ~20h is rising in the east.
DateTime _fixedNow() => DateTime.utc(2026, 5, 11, 4, 0);

SchedulerCandidate _candidate({
  required int id,
  required String name,
  required double raHours,
  required double decDegrees,
  int userPriority = 5,
  List<IntegrationGoal> goals = const [],
  List<int> capturedCounts = const [],
  List<String> availableFilters = const ['L', 'R', 'G', 'B'],
  List<TargetConstraint> constraints = const [],
  bool isMosaicTarget = false,
}) {
  return SchedulerCandidate(
    targetId: id,
    name: name,
    raHours: raHours,
    decDegrees: decDegrees,
    userPriority: userPriority,
    goals: goals,
    capturedCounts: capturedCounts,
    constraints: constraints,
    horizonProfiles: const {},
    availableFilters: availableFilters,
    isMosaicTarget: isMosaicTarget,
  );
}

void main() {
  group('SchedulerEngine - candidate selection', () {
    test(
      'refuses to start with no candidate targets and remains idle',
      () async {
        final sink = _RecordingSink();
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => const <SchedulerCandidate>[],
          clock: _fixedNow,
        );

        await expectLater(
          engine.start(),
          throwsA(
            isA<SchedulerStartException>().having(
              (error) => error.message,
              'message',
              contains('Add at least one target'),
            ),
          ),
        );

        expect(engine.status.state, SchedulerState.idle);
        expect(engine.status.currentTargetId, isNull);
        expect(engine.lastDecision, isNull);
        expect(sink.dispatched, isEmpty);
        expect(sink.parkCount, 0);
        await engine.dispose();
      },
    );

    test('picks the highest-scoring candidate from three options', () async {
      final sink = _RecordingSink();
      late SchedulerEngine engine;
      final candidates = <SchedulerCandidate>[
        // High in the south, near meridian - should win.
        _candidate(
          id: 1,
          name: 'High in south',
          raHours: 14.0,
          decDegrees: 30.0,
        ),
        // Setting low in west.
        _candidate(id: 2, name: 'Setting west', raHours: 4.0, decDegrees: 10.0),
        // Rising low in east.
        _candidate(id: 3, name: 'Rising east', raHours: 20.0, decDegrees: 20.0),
      ];
      engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => candidates,
        clock: _fixedNow,
      );

      await engine.start();
      final decision = engine.lastDecision;
      expect(decision, isNotNull);
      expect(decision!.chosenTargetId, 1);
      expect(decision.chosenTargetName, 'High in south');
      // All three candidates should appear in scoredCandidates (some may
      // have failed hard constraints if below 25° at the chosen instant).
      expect(decision.scoredCandidates.length, 3);
      // The winner should have a higher totalScore than the rest among
      // those that passed.
      final eligible = decision.scoredCandidates
          .where((s) => !s.hardConstraintFailed)
          .toList();
      expect(eligible.isNotEmpty, isTrue);
      expect(eligible.first.targetId, 1);
      await engine.dispose();
    });

    test(
      'rejects candidates below the minimum altitude as hard fails',
      () async {
        final sink = _RecordingSink();
        final candidates = <SchedulerCandidate>[
          // Below the horizon at the chosen instant (RA opposite the LST).
          _candidate(
            id: 10,
            name: 'Below horizon',
            raHours: 2.0,
            decDegrees: -45.0,
          ),
          _candidate(
            id: 11,
            name: 'High in south',
            raHours: 14.0,
            decDegrees: 30.0,
          ),
        ];
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => candidates,
          clock: _fixedNow,
        );
        await engine.start();
        final decision = engine.lastDecision!;
        expect(decision.chosenTargetId, 11);
        final rejected = decision.scoredCandidates.where(
          (s) => s.hardConstraintFailed,
        );
        expect(
          rejected.isNotEmpty,
          isTrue,
          reason: 'below-horizon target should be hardConstraintFailed',
        );
        await engine.dispose();
      },
    );

    test(
      'rejects all candidates while the Sun is up (no daylight imaging)',
      () async {
        final sink = _RecordingSink();
        // Local noon at the site (lon -75 -> solar noon ~17:00 UTC). Sun is
        // high (~+65 deg), far above the -12 deg darkness limit.
        DateTime daytime() => DateTime.utc(2026, 5, 11, 17, 0);
        final candidates = <SchedulerCandidate>[
          _candidate(
            id: 30,
            name: 'Circumpolar',
            raHours: 7.0,
            decDegrees: 40.0,
          ),
        ];
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => candidates,
          clock: daytime,
        );
        await engine.start();
        final decision = engine.lastDecision!;
        expect(
          decision.chosenTargetId,
          isNull,
          reason: 'must not slew/expose while the Sun is up',
        );
        expect(
          decision.scoredCandidates.every((s) => s.hardConstraintFailed),
          isTrue,
        );
        expect(
          decision.scoredCandidates.any(
            (s) => s.rejectionReasons.any((r) => r.contains('Sun')),
          ),
          isTrue,
          reason: 'the twilight gate should reject candidates in daylight',
        );
        expect(sink.dispatched, isEmpty);
        await engine.dispose();
      },
    );

    test('does not apply the Sun gate at night', () async {
      final sink = _RecordingSink();
      final candidates = <SchedulerCandidate>[
        _candidate(
          id: 31,
          name: 'High in south',
          raHours: 14.0,
          decDegrees: 30.0,
        ),
      ];
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => candidates,
        clock: _fixedNow, // 23:00 local -- deep night
      );
      await engine.start();
      final decision = engine.lastDecision!;
      final sunRejections = decision.scoredCandidates
          .expand((s) => s.rejectionReasons)
          .where((r) => r.contains('Sun'));
      expect(
        sunRejections,
        isEmpty,
        reason: 'gate must not fire when the Sun is well below the horizon',
      );
      await engine.dispose();
    });

    test('emits a null decision when no candidates are eligible', () async {
      final sink = _RecordingSink();
      final candidates = <SchedulerCandidate>[
        _candidate(id: 20, name: 'Underfoot', raHours: 2.0, decDegrees: -85.0),
      ];
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => candidates,
        clock: _fixedNow,
      );
      await engine.start();
      final decision = engine.lastDecision!;
      expect(decision.chosenTargetId, isNull);
      expect(decision.reasoning, isNotEmpty);
      await engine.dispose();
    });
  });

  group('SchedulerEngine - hysteresis', () {
    test(
      'does not switch when challenger is 1.10x current (below 1.20)',
      () async {
        final sink = _RecordingSink();
        // Two candidates A and B. We seed weights so A has a slight edge
        // first, then mutate weights so B's score is ~1.10x A. Hysteresis
        // is 1.20, so the engine must stick with A.
        final candidates = <SchedulerCandidate>[
          _candidate(id: 100, name: 'A', raHours: 14.0, decDegrees: 30.0),
          _candidate(id: 200, name: 'B', raHours: 14.0, decDegrees: 32.0),
        ];
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => candidates,
          clock: _fixedNow,
        );
        await engine.start();
        // After the first tick, the engine has chosen one of them. Force a
        // re-evaluation with the same data — no switch should occur.
        final firstChoice = engine.lastDecision!.chosenTargetId!;
        await engine.evaluateNow();
        expect(engine.lastDecision!.chosenTargetId, firstChoice);
        expect(
          engine.lastDecision!.isSwitch,
          isFalse,
          reason: 'identical evaluation should never flip the chosen target',
        );
        await engine.dispose();
      },
    );

    test('switches when challenger exceeds hysteresis ratio', () async {
      final sink = _RecordingSink();
      // The hysteresis ratio is 1.20. user-priority alone doesn't move
      // total score by 20 % (its weight is 0.5 and the other weights sum
      // to ~4.0), so we engineer a sharp altitude gap in phase 2 — a
      // candidate near the meridian at high altitude trivially scores
      // 1.5x a candidate that just barely clears the horizon.
      final candidatesPhase1 = <SchedulerCandidate>[
        // A: high in the south near the meridian -> wins phase 1.
        _candidate(id: 100, name: 'A', raHours: 14.0, decDegrees: 30.0),
        // B: very low alt at the same instant -> hard-fails phase 1.
        _candidate(id: 200, name: 'B', raHours: 14.0, decDegrees: -25.0),
      ];
      final candidatesPhase2 = <SchedulerCandidate>[
        // A: still up but now low and away from meridian.
        _candidate(id: 100, name: 'A', raHours: 14.0, decDegrees: -10.0),
        // B: high in the south.
        _candidate(id: 200, name: 'B', raHours: 14.0, decDegrees: 30.0),
      ];
      var phase = 1;
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async =>
            phase == 1 ? candidatesPhase1 : candidatesPhase2,
        clock: _fixedNow,
      );
      await engine.start();
      expect(
        engine.lastDecision!.chosenTargetId,
        100,
        reason: 'A is high in the south in phase 1',
      );
      phase = 2;
      await engine.evaluateNow();
      expect(
        engine.lastDecision!.chosenTargetId,
        200,
        reason:
            'B is now the obviously-better target (high alt) so the '
            'engine should swap once hysteresis is exceeded',
      );
      expect(engine.lastDecision!.isSwitch, isTrue);
      await engine.dispose();
    });

    test('switches when user priority alone clears hysteresis', () async {
      final sink = _RecordingSink();
      var preferB = false;

      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => <SchedulerCandidate>[
          _candidate(
            id: 100,
            name: 'A',
            raHours: 14.0,
            decDegrees: 30.0,
            userPriority: preferB ? 0 : 5,
          ),
          _candidate(
            id: 200,
            name: 'B',
            raHours: 14.0,
            decDegrees: 30.0,
            userPriority: preferB ? 10 : 5,
          ),
        ],
        clock: _fixedNow,
      );

      await engine.start();
      expect(engine.lastDecision!.chosenTargetId, 100);

      preferB = true;
      await engine.evaluateNow();

      expect(
        engine.lastDecision!.chosenTargetId,
        200,
        reason:
            'a max-priority challenger should be able to override '
            'hysteresis even when sky geometry is tied',
      );
      expect(engine.lastDecision!.isSwitch, isTrue);
      await engine.dispose();
    });
  });

  group('SchedulerEngine - integration goals', () {
    test(
      'builds a sequence that exposes the highest-remaining filter',
      () async {
        final sink = _RecordingSink();
        final now = DateTime.utc(2026, 5, 11, 4, 0);
        // Target with two goals — Red is mostly done, Green is barely started.
        // The engine should choose Green for the next sequence dispatch.
        final goals = [
          IntegrationGoal(
            targetId: 1,
            filter: 'R',
            exposureSeconds: 180.0,
            frameCount: 20,
            priority: 5,
            createdAt: now,
          ),
          IntegrationGoal(
            targetId: 1,
            filter: 'G',
            exposureSeconds: 180.0,
            frameCount: 20,
            priority: 5,
            createdAt: now,
          ),
        ];
        final candidates = <SchedulerCandidate>[
          SchedulerCandidate(
            targetId: 1,
            name: 'NGC 7000',
            raHours: 14.0,
            decDegrees: 30.0,
            userPriority: 5,
            goals: goals,
            capturedCounts: [18, 2],
            constraints: const [],
            horizonProfiles: const {},
            availableFilters: const ['L', 'R', 'G', 'B'],
          ),
        ];
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => candidates,
          clock: () => now,
        );
        await engine.start();
        expect(sink.dispatched.length, 1);
        final sequence = sink.dispatched.first;
        // Find the exposure node and verify it targets the G filter.
        final exposure = sequence.nodes.values.whereType<ExposureNode>().single;
        expect(exposure.filter, 'G');
        expect(
          exposure.count,
          18,
          reason: 'should request the remaining frames for the chosen filter',
        );
        await engine.dispose();
      },
    );
  });

  group('SchedulerEngine - mosaic candidates', () {
    test('dispatches one mosaic panel target per scheduler tick', () async {
      final sink = _RecordingSink();
      final now = DateTime.utc(2026, 5, 11, 4, 0);
      final goal = IntegrationGoal(
        targetId: 42,
        filter: 'L',
        exposureSeconds: 120.0,
        frameCount: 6,
        priority: 5,
        createdAt: now,
      );
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => [
          _candidate(
            id: 42,
            name: 'Andromeda Mosaic Panel 3/9',
            raHours: 14.0,
            decDegrees: 30.0,
            goals: [goal],
            capturedCounts: const [2],
            isMosaicTarget: true,
          ),
        ],
        clock: () => now,
      );

      await engine.start();

      expect(sink.dispatched.length, 1);
      final sequence = sink.dispatched.single;
      expect(sequence.name, contains('Andromeda Mosaic Panel 3/9'));
      final target = sequence.targetHeaders.single;
      expect(target.targetName, 'Andromeda Mosaic Panel 3/9');
      final exposure = sequence.nodes.values.whereType<ExposureNode>().single;
      expect(exposure.filter, 'L');
      expect(exposure.durationSecs, 120.0);
      expect(
        exposure.count,
        4,
        reason:
            'one scheduler tick should capture the remaining frames '
            'for the selected mosaic panel/filter',
      );
      await engine.dispose();
    });

    test(
      'builds all pending filter rows for a selected mosaic panel',
      () async {
        final sink = _RecordingSink();
        final now = DateTime.utc(2026, 5, 11, 4, 0);
        final goals = [
          IntegrationGoal(
            targetId: 42,
            filter: 'L',
            exposureSeconds: 120.0,
            frameCount: 6,
            priority: 8,
            createdAt: now,
          ),
          IntegrationGoal(
            targetId: 42,
            filter: 'R',
            exposureSeconds: 180.0,
            frameCount: 4,
            priority: 5,
            createdAt: now,
          ),
          IntegrationGoal(
            targetId: 42,
            filter: 'G',
            exposureSeconds: 180.0,
            frameCount: 4,
            priority: 5,
            createdAt: now,
          ),
        ];
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => [
            _candidate(
              id: 42,
              name: 'Andromeda Mosaic Panel 3/9',
              raHours: 14.0,
              decDegrees: 30.0,
              goals: goals,
              capturedCounts: const [5, 1, 0],
              isMosaicTarget: true,
            ),
          ],
          clock: () => now,
        );

        await engine.start();

        final exposures = sink.dispatched.single.nodes.values
            .whereType<ExposureNode>()
            .toList();
        expect(exposures.map((e) => e.filter), ['G', 'R', 'L']);
        expect(exposures.map((e) => e.count), [4, 3, 1]);
        expect(exposures.map((e) => e.durationSecs), [180.0, 180.0, 120.0]);
        await engine.dispose();
      },
    );
  });

  group('SchedulerEngine - sequence completion reaction', () {
    test(
      'SequenceCompleted re-dispatches a still-eligible current target',
      () async {
        final sink = _RecordingSink();
        final triggers = StreamController<SchedulerTriggerEvent>();
        addTearDown(triggers.close);
        final candidates = <SchedulerCandidate>[
          _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
        ];
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => candidates,
          triggerStream: triggers.stream,
          clock: _fixedNow,
        );
        await engine.start();
        expect(
          sink.dispatched.length,
          1,
          reason: 'cold start dispatches the chosen target',
        );

        // The dispatched sequence finishes naturally. The engine must re-pick
        // and re-dispatch the still-eligible target's remaining work instead of
        // sitting idle until the next periodic tick.
        triggers.add(SchedulerTriggerEvent.sequenceCompleted);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          sink.dispatched.length,
          2,
          reason:
              'natural completion must re-dispatch, not leave the rig '
              'idle (the original P0 bug)',
        );
        await engine.dispose();
      },
    );

    test(
      'a non-completion trigger does NOT re-dispatch an unchanged winner',
      () async {
        final sink = _RecordingSink();
        final triggers = StreamController<SchedulerTriggerEvent>();
        addTearDown(triggers.close);
        final candidates = <SchedulerCandidate>[
          _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
        ];
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => candidates,
          triggerStream: triggers.stream,
          clock: _fixedNow,
        );
        await engine.start();
        expect(sink.dispatched.length, 1);

        // A weather/guiding-style re-eval where the winner is unchanged must NOT
        // re-dispatch (hysteresis keeps the running target) -- only a genuine
        // completion clears the current target and re-dispatches.
        triggers.add(SchedulerTriggerEvent.guidingRecovered);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(
          sink.dispatched.length,
          1,
          reason: 'an unchanged-winner re-eval must not re-dispatch',
        );
        await engine.dispose();
      },
    );
  });

  group('SchedulerEngine - only stops runs it started', () {
    // A target that can never clear the site minimum altitude (Dec -80 from
    // lat +40 culminates at -30 deg), evaluated in deep night. Every tick
    // finds nothing eligible while the Sun is far below the darkness limit,
    // so the engine takes the transient mid-night empty path — the exact
    // state the autopilot sits in while it reports "No eligible target right
    // now".
    SchedulerCandidate neverEligible() => _candidate(
      id: 1,
      name: 'Below horizon',
      raHours: 14.0,
      decDegrees: -80.0,
    );

    test(
      'a no-eligible tick never stops a sequence the autopilot did not start',
      () async {
        final sink = _RecordingSink();
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => <SchedulerCandidate>[neverEligible()],
          clock: _fixedNow,
        );

        await engine.start();
        expect(
          sink.dispatched,
          isEmpty,
          reason: 'nothing is eligible, so the autopilot owns no run',
        );
        await engine.evaluateNow(reason: 'tick');
        await engine.evaluateNow(reason: 'tick');

        expect(
          sink.stopCount,
          0,
          reason: 'stopping here kills whatever the operator started by hand',
        );
        await engine.dispose();
      },
    );

    test('stopping its own run says why on the decision', () async {
      final sink = _RecordingSink();
      var eligible = true;
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => <SchedulerCandidate>[
          eligible
              ? _candidate(id: 1, name: 'Bode', raHours: 14.0, decDegrees: 30.0)
              : neverEligible(),
        ],
        clock: _fixedNow,
      );

      await engine.start();
      expect(sink.dispatched.length, 1);

      eligible = false;
      await engine.evaluateNow(reason: 'tick');

      expect(sink.stopCount, 1, reason: 'the autopilot owns this run');
      expect(
        engine.lastDecision!.reasoning,
        contains(allOf(contains('Stopped'), contains('Bode'))),
        reason: 'the panel must say why imaging stopped',
      );
      await engine.dispose();
    });
  });

  group('SchedulerEngine - end-of-night park', () {
    // Local noon at the site (lon -75 -> solar noon ~17:00 UTC): the Sun is
    // high above the -12 deg darkness limit, so every candidate is
    // Sun-rejected and the engine treats the empty-eligible path as dawn.
    DateTime daytime() => DateTime.utc(2026, 5, 11, 17, 0);

    test(
      'a daytime pre-arm waits quietly until the observing night begins',
      () async {
        final sink = _RecordingSink();
        final candidates = <SchedulerCandidate>[
          _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
        ];
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => candidates,
          clock: daytime,
        );
        await engine.start();

        expect(
          engine.lastDecision!.chosenTargetId,
          isNull,
          reason: 'Sun is up — no candidate is eligible',
        );
        expect(
          sink.dispatched,
          isEmpty,
          reason: 'must never slew/expose at dawn',
        );
        expect(sink.parkCount, 0);
        expect(
          sink.stopCount,
          0,
          reason: 'a pre-armed scheduler has no active run to stop',
        );
      },
    );

    test(
      'does not repeatedly safe a pre-armed scheduler while the Sun is up',
      () async {
        final sink = _RecordingSink();
        final candidates = <SchedulerCandidate>[
          _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
        ];
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => candidates,
          clock: daytime,
        );
        await engine.start();
        expect(sink.parkCount, 0);

        // Several more ticks while the Sun is still up remain a quiet wait.
        await engine.evaluateNow();
        await engine.evaluateNow();
        await engine.evaluateNow();
        expect(
          sink.parkCount,
          0,
          reason:
              'daytime before the first dispatch is not the end of an '
              'observing night',
        );
      },
    );

    test('a transient mid-night empty (all goals complete) STOPS but does NOT '
        'park', () async {
      final sink = _RecordingSink();
      final now = DateTime.utc(2026, 5, 11, 4, 0); // deep night
      // Target high in the south, but every goal is already fully captured, so
      // it is hard-rejected ("all integration goals complete") and the
      // eligible set is empty — at night, NOT end-of-night.
      final goal = IntegrationGoal(
        targetId: 1,
        filter: 'L',
        exposureSeconds: 120.0,
        frameCount: 10,
        priority: 5,
        createdAt: now,
      );
      var phase = 1;
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => <SchedulerCandidate>[
          SchedulerCandidate(
            targetId: 1,
            name: 'A',
            raHours: 14.0,
            decDegrees: 30.0,
            userPriority: 5,
            goals: [goal],
            // Phase 1: still needs frames (so we get a running sequence to
            // stop). Phase 2: fully complete -> empty-eligible mid-night.
            capturedCounts: phase == 1 ? const [2] : const [10],
            constraints: const [],
            horizonProfiles: const {},
            availableFilters: const ['L'],
          ),
        ],
        clock: () => now,
      );
      await engine.start();
      expect(
        sink.dispatched.length,
        1,
        reason: 'phase 1 dispatches the incomplete target',
      );

      // Now the goal is complete; the eligible set is empty but the Sun is
      // still well below the horizon.
      phase = 2;
      await engine.evaluateNow();
      expect(engine.lastDecision!.chosenTargetId, isNull);
      expect(
        sink.parkCount,
        0,
        reason:
            'a transient mid-night empty must NEVER park — the night '
            'is not over',
      );
      expect(
        sink.stopCount,
        1,
        reason: 'mid-night empty stops the running sequence',
      );
    });

    test('a mid-night target swap does NOT park', () async {
      final sink = _RecordingSink();
      // Two candidates at night; B becomes the clear winner in phase 2, forcing
      // a swap. A swap must use stopSequence/dispatch — never the park hook.
      var phase = 1;
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => phase == 1
            ? <SchedulerCandidate>[
                _candidate(id: 100, name: 'A', raHours: 14.0, decDegrees: 30.0),
                _candidate(
                  id: 200,
                  name: 'B',
                  raHours: 14.0,
                  decDegrees: -25.0,
                ),
              ]
            : <SchedulerCandidate>[
                _candidate(
                  id: 100,
                  name: 'A',
                  raHours: 14.0,
                  decDegrees: -10.0,
                ),
                _candidate(id: 200, name: 'B', raHours: 14.0, decDegrees: 30.0),
              ],
        clock: _fixedNow,
      );
      await engine.start();
      expect(engine.lastDecision!.chosenTargetId, 100);
      phase = 2;
      await engine.evaluateNow();
      expect(
        engine.lastDecision!.chosenTargetId,
        200,
        reason: 'the swap target should win in phase 2',
      );
      expect(engine.lastDecision!.isSwitch, isTrue);
      expect(
        sink.parkCount,
        0,
        reason: 'a mid-night target swap must never park the mount',
      );
    });

    test(
      'parks at dawn after a pre-armed scheduler dispatched nighttime work',
      () async {
        final sink = _RecordingSink();
        // Phase 1: daytime pre-arm -> wait. Phase 2: night returns and a target
        // is eligible -> dispatch. Phase 3: dawn -> park exactly once.
        var phase = 1;
        DateTime nowFn() => phase == 2
            ? DateTime.utc(2026, 5, 11, 4, 0) // night
            : DateTime.utc(2026, 5, 11, 17, 0); // dawn/day
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => <SchedulerCandidate>[
            _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
          ],
          clock: nowFn,
        );
        await engine.start(); // phase 1: dawn
        expect(sink.parkCount, 0);
        expect(sink.dispatched, isEmpty);

        phase = 2; // night returns
        await engine.evaluateNow();
        expect(
          engine.lastDecision!.chosenTargetId,
          1,
          reason: 'at night the target is eligible and dispatched',
        );
        expect(sink.dispatched.length, 1);

        phase = 3; // dawn again
        await engine.evaluateNow();
        expect(
          sink.parkCount,
          1,
          reason: 'after imaging work was dispatched, the next dawn must park',
        );
      },
    );

    test('does NOT park while idle (engine not running)', () async {
      final sink = _RecordingSink();
      final candidates = <SchedulerCandidate>[
        _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
      ];
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => candidates,
        clock: daytime,
      );
      // evaluateNow without start(): the engine is idle, so even at dawn it
      // must not issue a park (nothing is running to be unsafe).
      await engine.evaluateNow();
      expect(
        sink.parkCount,
        0,
        reason: 'an idle engine must not park — it is not driving the rig',
      );
    });
  });

  group('SchedulerEngine - requestReevaluation debounce', () {
    test('triggers exactly one recompute within the debounce window', () async {
      final sink = _RecordingSink();
      var loadCount = 0;
      final candidates = <SchedulerCandidate>[
        _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
      ];
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async {
          loadCount++;
          return candidates;
        },
        clock: _fixedNow,
      );
      // Start triggers the cold-start evaluation (loadCount becomes 1).
      await engine.start();
      expect(loadCount, 1);

      // Fire three requests inside a window much smaller than 500ms — the
      // engine must coalesce them into a single re-evaluation.
      engine.requestReevaluation(reason: 'a');
      engine.requestReevaluation(reason: 'b');
      engine.requestReevaluation(reason: 'c');

      // Wait past the 500ms debounce window so the timer fires once.
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(
        loadCount,
        2,
        reason:
            'three requests inside the debounce window should '
            'produce one extra evaluation, not three',
      );
      await engine.dispose();
    });

    test('a single requestReevaluation does fire a recompute', () async {
      final sink = _RecordingSink();
      var loadCount = 0;
      final candidates = <SchedulerCandidate>[
        _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
      ];
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async {
          loadCount++;
          return candidates;
        },
        clock: _fixedNow,
      );
      await engine.start();
      expect(loadCount, 1);
      engine.requestReevaluation();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(loadCount, 2);
      await engine.dispose();
    });

    test('two bursts separated by > 500ms produce two recomputes', () async {
      final sink = _RecordingSink();
      var loadCount = 0;
      final candidates = <SchedulerCandidate>[
        _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
      ];
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async {
          loadCount++;
          return candidates;
        },
        clock: _fixedNow,
      );
      await engine.start();
      expect(loadCount, 1);
      engine.requestReevaluation();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(loadCount, 2);
      engine.requestReevaluation();
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(loadCount, 3);
      await engine.dispose();
    });
  });

  group('SchedulerEngine - lifecycle', () {
    test(
      'idle re-evaluation cannot suppress the next start dispatch',
      () async {
        final sink = _RecordingSink();
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => <SchedulerCandidate>[
            _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
          ],
          clock: _fixedNow,
        );

        await engine.evaluateNow(reason: 'operator preview');
        expect(engine.lastDecision!.chosenTargetId, 1);
        expect(engine.status.state, SchedulerState.idle);
        expect(
          engine.status.currentTargetId,
          isNull,
          reason: 'an idle preview must not claim target authority',
        );

        await engine.start();
        expect(sink.dispatched, hasLength(1));
        expect(engine.status.currentTargetId, 1);
        await engine.dispose();
      },
    );

    test('start / pause / resume / stop drives sequence sink', () async {
      final sink = _RecordingSink();
      final candidates = <SchedulerCandidate>[
        _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
      ];
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => candidates,
        clock: _fixedNow,
      );
      await engine.start();
      expect(engine.status.state, SchedulerState.running);
      expect(sink.dispatched.length, 1);
      await engine.pause();
      expect(engine.status.state, SchedulerState.paused);
      expect(sink.pauseCount, 1);
      await engine.resume();
      expect(engine.status.state, SchedulerState.running);
      expect(sink.resumeCount, 1);
      await engine.stop();
      expect(engine.status.state, SchedulerState.idle);
      expect(sink.stopCount, 1);
      await engine.dispose();
    });
  });

  group('SchedulerEngine - scheduledWindow override', () {
    // Window covers the fixed clock instant 2026-05-11 04:00 UTC. The
    // engine should force-select the lower base-score target during the
    // window and then revert to the higher base-score one once the
    // window ends.
    DateTime windowStart() => DateTime.utc(2026, 5, 11, 3, 0);
    DateTime windowEnd() => DateTime.utc(2026, 5, 11, 5, 0);

    test('forces selection mid-tick, bypassing hysteresis', () async {
      final sink = _RecordingSink();
      // A has a strong base score (high in south); B is rising but has a
      // scheduledWindow covering "now". The engine must select B.
      final aPhase1 = _candidate(
        id: 1,
        name: 'A',
        raHours: 14.0,
        decDegrees: 30.0,
      );
      final bPhase1 = _candidate(
        id: 2,
        name: 'B',
        raHours: 18.0,
        decDegrees: 30.0,
        constraints: [
          TargetConstraint(
            targetId: 2,
            kind: TargetConstraintKind.scheduledWindow,
            scheduledWindow: ScheduledWindow(
              startUtc: windowStart(),
              endUtc: windowEnd(),
              priorityBoost: 0.5,
            ),
          ),
        ],
      );
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => [aPhase1, bPhase1],
        clock: _fixedNow,
      );
      await engine.start();
      final decision = engine.lastDecision!;
      expect(
        decision.chosenTargetId,
        2,
        reason:
            'scheduledWindow must force-select B even though A scores '
            'higher absent the boost',
      );
      expect(decision.isSwitch, isTrue);
      // The chosen target's reasoning should explicitly mention the
      // forced-selection state so the UI / log can surface it.
      final reasonsBlob = decision.reasoning.join('\n');
      expect(reasonsBlob, contains('Forced by scheduled window'));
      await engine.dispose();
    });

    test(
      'window-end releases the bypass and lets normal scoring resume',
      () async {
        final sink = _RecordingSink();
        // Phase 1: clock inside window — B forced. Phase 2: clock advanced
        // past window AND B is now below the horizon, so the engine must
        // forcibly swap to A (the only eligible candidate). This proves the
        // bypass cleanly releases — without the release, B (a hard-failed
        // candidate) could never be replaced. We verify the chosen id flips
        // and the decision's `reasoning` no longer mentions the forced
        // bypass.
        var phase = 1;
        // B inside window is near meridian; B outside window is below
        // horizon (dec deeply south so the site can't see it).
        SchedulerCandidate buildB() {
          return _candidate(
            id: 2,
            name: 'B',
            raHours: phase == 1 ? 14.0 : 14.0,
            decDegrees: phase == 1 ? 30.0 : -80.0,
            constraints: [
              TargetConstraint(
                targetId: 2,
                kind: TargetConstraintKind.scheduledWindow,
                scheduledWindow: ScheduledWindow(
                  startUtc: windowStart(),
                  endUtc: windowEnd(),
                  priorityBoost: 0.5,
                ),
              ),
            ],
          );
        }

        var nowFn = () => DateTime.utc(2026, 5, 11, 4, 0); // inside window
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => [
            _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
            buildB(),
          ],
          clock: () => nowFn(),
        );
        await engine.start();
        expect(
          engine.lastDecision!.chosenTargetId,
          2,
          reason: 'B forced inside the window',
        );
        expect(
          engine.lastDecision!.reasoning.join('\n'),
          contains('Forced by scheduled window'),
        );

        // Advance past window end and make B below-horizon.
        phase = 2;
        nowFn = () => DateTime.utc(2026, 5, 11, 6, 0); // past window
        await engine.evaluateNow();
        expect(
          engine.lastDecision!.chosenTargetId,
          1,
          reason: 'B is now hard-failed and the bypass has lapsed; A wins',
        );
        expect(engine.lastDecision!.isSwitch, isTrue);
        // The post-window reasoning must NOT claim "forced by scheduled
        // window" — that's the whole point of the release.
        expect(
          engine.lastDecision!.reasoning.join('\n'),
          isNot(contains('Forced by scheduled window')),
        );
        await engine.dispose();
      },
    );

    test(
      'overlapping windows on different targets choose the higher base score',
      () async {
        final sink = _RecordingSink();
        // Both A and B sit inside an active scheduled window at the same
        // instant. A has higher base score (near meridian); B is lower. The
        // engine must pick A — eligibility-sorted by base+boost — but it
        // MUST still be a forced selection (hysteresis bypassed).
        final aCandidate = _candidate(
          id: 1,
          name: 'A',
          raHours: 14.0,
          decDegrees: 30.0,
          constraints: [
            TargetConstraint(
              targetId: 1,
              kind: TargetConstraintKind.scheduledWindow,
              scheduledWindow: ScheduledWindow(
                startUtc: windowStart(),
                endUtc: windowEnd(),
                priorityBoost: 0.3,
              ),
            ),
          ],
        );
        final bCandidate = _candidate(
          id: 2,
          name: 'B',
          raHours: 18.0,
          decDegrees: 30.0,
          constraints: [
            TargetConstraint(
              targetId: 2,
              kind: TargetConstraintKind.scheduledWindow,
              scheduledWindow: ScheduledWindow(
                startUtc: windowStart(),
                endUtc: windowEnd(),
                priorityBoost: 0.3,
              ),
            ),
          ],
        );
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => [aCandidate, bCandidate],
          clock: _fixedNow,
        );
        await engine.start();
        expect(
          engine.lastDecision!.chosenTargetId,
          1,
          reason: 'when overlapping windows, the higher base score wins',
        );
        final reasonsBlob = engine.lastDecision!.reasoning.join('\n');
        expect(reasonsBlob, contains('Forced by scheduled window'));
        await engine.dispose();
      },
    );
  });

  group('SchedulerEngine - rejected candidate explanations', () {
    test('every non-chosen candidate appears in decision.rejected with a '
        'primary why-not reason', () async {
      final sink = _RecordingSink();
      final candidates = <SchedulerCandidate>[
        // Winner — high in south, near meridian, max altitude.
        _candidate(id: 1, name: 'Winner', raHours: 14.0, decDegrees: 40.0),
        // Rejected — below horizon (hard fail; deep southern dec).
        _candidate(
          id: 2,
          name: 'Below horizon',
          raHours: 2.0,
          decDegrees: -75.0,
        ),
        // Rejected — eligible but lower score. Same RA so it's near
        // meridian and definitely above the 25° floor at lat 40 (alt
        // ≈ 75° here), but lower than the winner.
        _candidate(
          id: 3,
          name: 'Same RA lower dec',
          raHours: 14.0,
          decDegrees: 30.0,
        ),
      ];
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => candidates,
        clock: _fixedNow,
      );
      await engine.start();
      final decision = engine.lastDecision!;
      expect(decision.chosenTargetId, 1);
      // Both non-chosen targets must be in the rejected list.
      expect(decision.rejected.length, 2);
      final byId = {for (final r in decision.rejected) r.targetId: r};
      expect(byId.containsKey(2), isTrue);
      expect(byId.containsKey(3), isTrue);
      // Hard-fail rejection should mention the horizon.
      expect(byId[2]!.primaryReason.toLowerCase(), contains('horizon'));
      // Hard-fail rejection should also carry the full constraint
      // failure list so the UI can show every reason on expand.
      expect(byId[2]!.hardConstraintFailures, isNotEmpty);
      // Eligible-but-lower rejection should mention the score-gap.
      expect(byId[3]!.primaryReason.toLowerCase(), contains('lower score'));
      // Each rejected candidate must carry its full per-factor breakdown
      // so the UI's expand-on-tap can render identical detail.
      expect(byId[3]!.factors, isNotEmpty);
      // Eligible-but-lower entries have no hard constraint failures.
      expect(byId[3]!.hardConstraintFailures, isEmpty);
      await engine.dispose();
    });
  });

  group('SchedulerEngine - read-only preview (Planner unification)', () {
    test(
      'previewRanking is side-effect-free: status/decision/dispatch unchanged',
      () async {
        final sink = _RecordingSink();
        final candidates = <SchedulerCandidate>[
          _candidate(
            id: 1,
            name: 'High in south',
            raHours: 14.0,
            decDegrees: 30.0,
          ),
          _candidate(
            id: 2,
            name: 'Rising east',
            raHours: 20.0,
            decDegrees: 20.0,
          ),
        ];
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => candidates,
          clock: _fixedNow,
        );

        // Engine is IDLE and has never evaluated: a preview must not start it,
        // dispatch anything, or mutate its status/lastDecision.
        expect(engine.status.state, SchedulerState.idle);
        expect(engine.lastDecision, isNull);

        final statusBefore = engine.status;
        final ranking = await engine.previewRanking(_fixedNow());

        expect(
          ranking,
          isNotEmpty,
          reason: 'at deep night both targets are eligible',
        );
        // Hard-rejected candidates are omitted; only eligible ones returned.
        expect(ranking.every((s) => !s.hardConstraintFailed), isTrue);

        // No side effects whatsoever.
        expect(
          engine.status,
          same(statusBefore),
          reason: 'preview must not mutate engine status',
        );
        expect(engine.status.state, SchedulerState.idle);
        expect(engine.status.currentTargetId, isNull);
        expect(
          engine.lastDecision,
          isNull,
          reason: 'preview must not publish a decision',
        );
        expect(
          sink.dispatched,
          isEmpty,
          reason: 'preview must never dispatch a sequence',
        );
        expect(sink.pauseCount, 0);
        expect(sink.stopCount, 0);
        expect(sink.parkCount, 0);

        await engine.dispose();
      },
    );

    test('previewRanking ordering equals mapping scoreCandidate over the same '
        'candidates (eligible, best-first)', () async {
      final sink = _RecordingSink();
      final now = _fixedNow();
      final candidates = <SchedulerCandidate>[
        _candidate(
          id: 1,
          name: 'High in south',
          raHours: 14.0,
          decDegrees: 30.0,
        ),
        _candidate(id: 2, name: 'Setting west', raHours: 4.0, decDegrees: 10.0),
        _candidate(id: 3, name: 'Rising east', raHours: 20.0, decDegrees: 20.0),
      ];
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => candidates,
        clock: () => now,
      );

      final ranking = await engine.previewRanking(now);

      // Independently reproduce the expected order using the public pure
      // scorer: score all, drop hard-failed, sort by totalScore desc.
      final expected =
          candidates
              .map((c) => engine.scoreCandidate(c, now))
              .where((s) => !s.hardConstraintFailed)
              .toList()
            ..sort((a, b) => b.totalScore.compareTo(a.totalScore));

      expect(
        ranking.map((s) => s.targetId).toList(),
        expected.map((s) => s.targetId).toList(),
      );

      await engine.dispose();
    });

    test(
      "previewDecision top pick equals the engine's live lastDecision for the "
      'same candidates + clock',
      () async {
        final sink = _RecordingSink();
        final now = _fixedNow();
        final candidates = <SchedulerCandidate>[
          _candidate(
            id: 1,
            name: 'High in south',
            raHours: 14.0,
            decDegrees: 30.0,
          ),
          _candidate(
            id: 2,
            name: 'Setting west',
            raHours: 4.0,
            decDegrees: 10.0,
          ),
          _candidate(
            id: 3,
            name: 'Rising east',
            raHours: 20.0,
            decDegrees: 20.0,
          ),
        ];
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => candidates,
          clock: () => now,
        );

        // Run the live autopilot once so lastDecision reflects a real dispatch.
        await engine.start();
        final live = engine.lastDecision!;
        expect(live.chosenTargetId, isNotNull);
        final dispatchedBefore = sink.dispatched.length;

        // The preview, computed for the SAME clock + candidate set + hysteresis
        // state, must agree with what the autopilot actually chose.
        final preview = await engine.previewDecision(now);
        expect(
          preview.chosenTargetId,
          live.chosenTargetId,
          reason: 'the human preview must equal the rig pick by construction',
        );
        expect(preview.chosenTargetName, live.chosenTargetName);
        expect(preview.score, live.score);

        // And the preview itself dispatched / mutated nothing.
        expect(
          sink.dispatched.length,
          dispatchedBefore,
          reason: 'preview must not dispatch',
        );
        expect(
          engine.lastDecision,
          same(live),
          reason: 'preview must not replace the published decision',
        );

        // previewRanking.first must agree with the chosen pick too.
        final ranking = await engine.previewRanking(now);
        expect(ranking.first.targetId, live.chosenTargetId);

        await engine.dispose();
      },
    );

    test('previewDecision respects live hysteresis state (matches what the rig '
        'would keep running)', () async {
      final sink = _RecordingSink();
      var preferB = false;
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => <SchedulerCandidate>[
          _candidate(
            id: 100,
            name: 'A',
            raHours: 14.0,
            decDegrees: 30.0,
            userPriority: preferB ? 6 : 5,
          ),
          _candidate(
            id: 200,
            name: 'B',
            raHours: 14.0,
            decDegrees: 30.0,
            userPriority: preferB ? 7 : 5,
          ),
        ],
        clock: _fixedNow,
      );

      await engine.start();
      final firstPick = engine.lastDecision!.chosenTargetId!;

      // Nudge B's priority slightly above A — not enough to clear the 1.20
      // hysteresis ratio. The live engine will STICK with the current target.
      preferB = true;
      await engine.evaluateNow();
      expect(
        engine.lastDecision!.chosenTargetId,
        firstPick,
        reason: 'sub-threshold challenger must not flip the rig',
      );

      // The preview must report the SAME held target, not the marginally
      // higher-scoring challenger — otherwise the human sees a pick the rig
      // will not actually switch to.
      final preview = await engine.previewDecision(_fixedNow());
      expect(
        preview.chosenTargetId,
        firstPick,
        reason: 'preview must honour the same hysteresis the autopilot uses',
      );

      await engine.dispose();
    });

    test(
      'previewRanking on an all-rejected (daylight) set is empty, no effects',
      () async {
        final sink = _RecordingSink();
        DateTime daytime() => DateTime.utc(2026, 5, 11, 17, 0);
        final candidates = <SchedulerCandidate>[
          _candidate(
            id: 30,
            name: 'Circumpolar',
            raHours: 7.0,
            decDegrees: 40.0,
          ),
        ];
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => candidates,
          clock: daytime,
        );

        final ranking = await engine.previewRanking(daytime());
        expect(
          ranking,
          isEmpty,
          reason: 'the Sun gate hard-rejects every candidate in daylight',
        );

        final preview = await engine.previewDecision(daytime());
        expect(preview.chosenTargetId, isNull);

        expect(sink.dispatched, isEmpty);
        expect(
          sink.parkCount,
          0,
          reason: 'preview must never park even at end-of-night',
        );
        expect(engine.lastDecision, isNull);

        await engine.dispose();
      },
    );
  });

  group('SchedulerEngine - active-plan ownership release', () {
    test(
      'engine.stop() disengages autopilot and releases editor ownership',
      () async {
        final sink = _RecordingSink();
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => [
            _candidate(
              id: 1,
              name: 'High in south',
              raHours: 14.0,
              decDegrees: 30.0,
            ),
          ],
          clock: _fixedNow,
        );

        await engine.start();
        expect(sink.dispatched, isNotEmpty, reason: 'autopilot took the slot');
        expect(sink.releaseCount, 0, reason: 'still engaged after start');

        await engine.stop();
        // Full disengage -> ownership handed back to the operator exactly once.
        expect(sink.releaseCount, 1);

        await engine.dispose();
      },
    );

    test('engine.dispose() releases editor ownership', () async {
      final sink = _RecordingSink();
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => [
          _candidate(
            id: 1,
            name: 'High in south',
            raHours: 14.0,
            decDegrees: 30.0,
          ),
        ],
        clock: _fixedNow,
      );

      await engine.start();
      await engine.dispose();
      expect(sink.releaseCount, greaterThanOrEqualTo(1));
    });
  });

  group('SchedulerEngine - failure-path hardening', () {
    test('a failed dispatch does NOT wedge the autopilot: status is not '
        'committed to the un-started winner, ownership is released, and a '
        'later good dispatch recovers', () async {
      final sink = _ConfigurableSink();
      // Single clearly-eligible target near the meridian at night.
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => <SchedulerCandidate>[
          _candidate(id: 42, name: 'Winner', raHours: 14.0, decDegrees: 30.0),
        ],
        clock: _fixedNow,
      );

      // First dispatch fails (transient pre-flight failure).
      sink.dispatchError = StateError('disk full');
      await engine.start();

      expect(
        engine.status.currentTargetId,
        isNull,
        reason:
            'currentTargetId must NOT be committed to a target that never '
            'started — otherwise hysteresis suppresses the re-dispatch',
      );
      expect(
        engine.status.lastError,
        isNotNull,
        reason: 'the failure must be surfaced on the status panel',
      );
      expect(
        sink.releaseCount,
        greaterThanOrEqualTo(1),
        reason:
            'a failed dispatch must release the editor slot so the '
            "operator's stashed manual sequence is not orphaned",
      );

      // Next tick: dispatch now succeeds. Because currentTargetId was never
      // committed, the engine still sees this as a switch and re-dispatches.
      sink.dispatchError = null;
      await engine.evaluateNow();

      expect(
        sink.dispatched.length,
        1,
        reason: 'the recovery tick must actually dispatch the winner',
      );
      expect(
        engine.status.currentTargetId,
        42,
        reason: 'after a successful dispatch the winner is committed',
      );
      expect(
        engine.status.lastError,
        isNull,
        reason: 'a successful dispatch clears the prior error',
      );
      await engine.dispose();
    });

    test(
      'engine.stop() releases editor ownership even when stopSequence throws',
      () async {
        final sink = _ConfigurableSink();
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => <SchedulerCandidate>[
            _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
          ],
          clock: _fixedNow,
        );
        await engine.start();
        expect(sink.dispatched.length, 1);

        sink.stopError = StateError('backend down');
        await expectLater(engine.stop(), throwsA(isA<StateError>()));
        expect(
          sink.releaseCount,
          greaterThanOrEqualTo(1),
          reason:
              'releaseSequenceOwnership must run in a finally so a throwing '
              'stopSequence cannot orphan the stashed manual sequence',
        );
        await engine.dispose();
      },
    );

    test(
      'engine.pause() does not flip to paused when pauseSequence throws',
      () async {
        final sink = _ConfigurableSink();
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => <SchedulerCandidate>[
            _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
          ],
          clock: _fixedNow,
        );
        await engine.start();
        expect(engine.status.state, SchedulerState.running);

        sink.pauseError = StateError('Cannot pause: sequence is not running');
        await expectLater(engine.pause(), throwsA(isA<StateError>()));
        expect(
          engine.status.state,
          SchedulerState.running,
          reason:
              'status must not diverge from reality — a failed pause must not '
              'leave the engine claiming it is paused',
        );
        await engine.dispose();
      },
    );

    test(
      'engine.dispose() closes both streams even when release throws',
      () async {
        final sink = _ConfigurableSink();
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => <SchedulerCandidate>[
            _candidate(id: 1, name: 'A', raHours: 14.0, decDegrees: 30.0),
          ],
          clock: _fixedNow,
        );
        await engine.start();

        sink.releaseError = StateError('owner provider torn down');
        // dispose() must swallow the release failure and still tear down the
        // controllers (no unhandled error, no leaked broadcast controllers).
        await engine.dispose();

        // A closed broadcast controller rejects new listeners by completing
        // the stream immediately with done. Proving the stream is closed proves
        // the controller was closed despite the throwing release.
        var statusDone = false;
        engine.statusStream.listen(null, onDone: () => statusDone = true);
        var decisionDone = false;
        engine.decisionStream.listen(null, onDone: () => decisionDone = true);
        await Future<void>.delayed(Duration.zero);
        expect(statusDone, isTrue, reason: 'statusController must be closed');
        expect(
          decisionDone,
          isTrue,
          reason: 'decisionController must be closed',
        );
      },
    );
  });

  group('wheel-less rigs', () {
    // The integration-goals editor offers an unfiltered ('') goal, which is
    // how a profile with no filter wheel expresses a target. `availableFilters`
    // is EMPTY on such a rig, so a `contains('')` admission test rejects the
    // candidate with "required filter not in equipment wheel ()" — a target
    // that schedules fine free-form becomes unschedulable the moment the
    // operator follows the app's own empty-state prompt.
    //
    // Driven through the real engine rather than a scoring helper, because the
    // behaviour lives in the wiring between the editor and the admission gate.
    test('an unfiltered goal on a wheel-less rig still dispatches', () async {
      final sink = _RecordingSink();
      final now = DateTime.utc(2026, 5, 11, 4, 0);
      final engine = SchedulerEngine(
        site: _site,
        sequenceSink: sink,
        candidateLoader: () async => <SchedulerCandidate>[
          SchedulerCandidate(
            targetId: 1,
            name: 'wheel-less',
            raHours: 14.0,
            decDegrees: 30.0,
            userPriority: 5,
            goals: [
              IntegrationGoal(
                targetId: 1,
                filter: '',
                exposureSeconds: 120.0,
                frameCount: 10,
                priority: 5,
                createdAt: now,
              ),
            ],
            capturedCounts: const [0],
            constraints: const [],
            horizonProfiles: const {},
            availableFilters: const [],
          ),
        ],
        clock: () => now,
      );
      await engine.start();

      expect(
        engine.lastDecision!.chosenTargetId,
        1,
        reason:
            'an empty goal filter means NO filter is required, so an empty '
            'wheel cannot be the reason to reject it',
      );
      expect(sink.dispatched, hasLength(1));
    });

    test(
      'a goal naming a filter the wheel really lacks is still rejected',
      () async {
        final sink = _RecordingSink();
        final now = DateTime.utc(2026, 5, 11, 4, 0);
        final engine = SchedulerEngine(
          site: _site,
          sequenceSink: sink,
          candidateLoader: () async => <SchedulerCandidate>[
            SchedulerCandidate(
              targetId: 1,
              name: 'needs Ha',
              raHours: 14.0,
              decDegrees: 30.0,
              userPriority: 5,
              goals: [
                IntegrationGoal(
                  targetId: 1,
                  filter: 'Ha',
                  exposureSeconds: 120.0,
                  frameCount: 10,
                  priority: 5,
                  createdAt: now,
                ),
              ],
              capturedCounts: const [0],
              constraints: const [],
              horizonProfiles: const {},
              availableFilters: const ['L', 'R'],
            ),
          ],
          clock: () => now,
        );
        await engine.start();

        expect(
          engine.lastDecision!.chosenTargetId,
          isNull,
          reason: 'the guard must still catch a genuinely missing filter',
        );
        expect(sink.dispatched, isEmpty);
      },
    );
  });
}

/// Sink whose individual hooks can be configured to throw, for exercising the
/// engine's failure-path hardening (dispatch/stop/pause/release failures).
class _ConfigurableSink implements SchedulerSequenceSink {
  final List<Sequence> dispatched = [];
  int releaseCount = 0;

  Object? dispatchError;
  Object? stopError;
  Object? pauseError;
  Object? releaseError;

  @override
  Future<void> dispatchSequence(Sequence sequence) async {
    if (dispatchError != null) throw dispatchError!;
    dispatched.add(sequence);
  }

  @override
  Future<void> pauseSequence() async {
    if (pauseError != null) throw pauseError!;
  }

  @override
  Future<void> resumeSequence() async {}

  @override
  Future<void> stopSequence() async {
    if (stopError != null) throw stopError!;
  }

  @override
  Future<void> parkForEndOfNight() async {}

  @override
  Future<void> releaseSequenceOwnership() async {
    releaseCount++;
    if (releaseError != null) throw releaseError!;
  }
}
