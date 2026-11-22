// Every way the scheduler engine rules a target out, as the operator sees it:
// the sentence on the row, the kind behind it, the chip, the decision record's
// short reason, and whether the target rising later clears it (which decides
// the Planner's "Up HH:MM" status).
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show AstronomyCalculations;
import 'package:skotiq_core/src/models/scheduler/integration_goal.dart';
import 'package:skotiq_core/src/models/scheduler/scheduler_decision.dart';
import 'package:skotiq_core/src/models/scheduler/scheduler_rejection.dart';
import 'package:skotiq_core/src/models/scheduler/target_constraint.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/models/site/horizon_profile.dart';
import 'package:skotiq_core/src/models/site/site_horizon_profile.dart';
import 'package:skotiq_core/src/services/scheduler/rejection_labels.dart';
import 'package:skotiq_core/src/services/scheduler/scheduler_engine.dart';

class _NullSink implements SchedulerSequenceSink {
  @override
  Future<void> dispatchSequence(Sequence sequence) async {}
  @override
  Future<void> pauseSequence() async {}
  @override
  Future<void> resumeSequence() async {}
  @override
  Future<void> stopSequence() async {}
  @override
  Future<void> releaseSequenceOwnership() async {}
  @override
  Future<void> parkForEndOfNight() async {}
}

const _site = SchedulerSite(
  latitudeDegrees: 45.0,
  longitudeDegrees: 21.0,
  localOffset: Duration(hours: 2),
);

/// Deep night at the site: the Sun gate never fires.
DateTime _night() => DateTime.utc(2026, 8, 13, 22, 50);

/// Early afternoon at the site.
DateTime _day() => DateTime.utc(2026, 8, 13, 11, 0);

final _created = DateTime.utc(2026, 1, 1);

SchedulerCandidate _candidate(
  int id, {
  double raHours = 18.0,
  double decDegrees = 89.9,
  List<IntegrationGoal> goals = const [],
  List<int> captured = const [],
  List<String> filters = const ['L'],
  List<TargetConstraint> constraints = const [],
  Map<int, HorizonProfile> horizonProfiles = const {},
}) => SchedulerCandidate(
  targetId: id,
  name: 'T$id',
  raHours: raHours,
  decDegrees: decDegrees,
  userPriority: 5,
  goals: goals,
  capturedCounts: captured,
  availableFilters: filters,
  constraints: constraints,
  horizonProfiles: horizonProfiles,
);

IntegrationGoal _goal(int id, String filter) => IntegrationGoal(
  targetId: id,
  filter: filter,
  exposureSeconds: 300,
  frameCount: 10,
  createdAt: _created,
);

typedef _Row = ({
  String sentence,
  SchedulerRejectionKind kind,
  String chip,
  String summary,
  bool curedByRising,
});

Future<SchedulerDecision> _decide(
  List<SchedulerCandidate> candidates, {
  SchedulerSite site = _site,
  DateTime Function() clock = _night,
}) async {
  final engine = SchedulerEngine(
    site: site,
    sequenceSink: _NullSink(),
    candidateLoader: () async => candidates,
    clock: clock,
  );
  addTearDown(engine.dispose);
  await engine.evaluateNow(reason: 'preview');
  return engine.lastDecision!;
}

_Row _rowFor(SchedulerDecision decision, int id) {
  final score = decision.scoredCandidates.firstWhere((s) => s.targetId == id);
  final rejected = decision.rejected.firstWhere((r) => r.targetId == id);
  final rejection = score.rejections.first;
  return (
    sentence: rejection.reason,
    kind: rejection.kind,
    chip: schedulerRejectionChipLabel(rejection),
    summary: rejected.primaryReason,
    curedByRising: rejection.kind.curedByRising,
  );
}

void main() {
  test('every hard constraint the engine applies at night', () async {
    final decision = await _decide([
      // Culminates near +9.8 deg: up, but under the 30 deg site minimum.
      _candidate(1, raHours: 21.42, decDegrees: -35.0),
      // Never rises.
      _candidate(2, raHours: 21.42, decDegrees: -80.0),
      _candidate(3, goals: [_goal(3, 'L')], captured: [10]),
      _candidate(4, goals: [_goal(4, 'Ha')], captured: [0]),
      _candidate(
        5,
        goals: [_goal(5, 'Ha'), _goal(5, 'OIII')],
        captured: [0, 0],
      ),
      _candidate(
        6,
        constraints: const [
          TargetConstraint(
            targetId: 6,
            kind: TargetConstraintKind.timeWindow,
            timeWindow: TargetTimeWindow(startMinutes: 120, endMinutes: 240),
          ),
        ],
      ),
      _candidate(
        7,
        constraints: const [
          TargetConstraint(
            targetId: 7,
            kind: TargetConstraintKind.moonIlluminationMax,
            moonIlluminationMax: 0.0,
          ),
        ],
      ),
      _candidate(
        8,
        constraints: const [
          TargetConstraint(
            targetId: 8,
            kind: TargetConstraintKind.moonSeparationMin,
            moonSeparationMinDeg: 179.0,
          ),
        ],
      ),
      _candidate(
        9,
        constraints: const [
          TargetConstraint(
            targetId: 9,
            kind: TargetConstraintKind.customHorizon,
            customHorizonId: 42,
          ),
        ],
      ),
      _candidate(
        10,
        constraints: const [
          TargetConstraint(
            targetId: 10,
            kind: TargetConstraintKind.customHorizon,
            customHorizonId: 7,
          ),
        ],
        horizonProfiles: {
          7: HorizonProfile.flat(id: 7, name: 'Oak', altitudeDegrees: 89.0),
        },
      ),
    ]);

    final expected = <int, _Row>{
      1: (
        sentence: 'altitude 10.0° below site minimum 30.0°',
        kind: SchedulerRejectionKind.tooLowForSite,
        chip: 'Too low',
        summary: 'too low (10.0° < site minimum 30.0°)',
        curedByRising: true,
      ),
      2: (
        sentence: 'altitude -34.9° below site minimum 30.0°',
        kind: SchedulerRejectionKind.belowHorizon,
        chip: 'Below horizon',
        summary: 'below horizon (-34.9°)',
        curedByRising: true,
      ),
      3: (
        sentence: 'all integration goals complete',
        kind: SchedulerRejectionKind.goalsComplete,
        chip: 'Complete',
        summary: 'all integration goals complete',
        curedByRising: false,
      ),
      4: (
        sentence: 'required filter not in equipment wheel (Ha)',
        kind: SchedulerRejectionKind.filterMissing,
        chip: 'Filter missing',
        summary: 'required filter not in wheel',
        curedByRising: false,
      ),
      5: (
        sentence: 'required filters not in equipment wheel (Ha, OIII)',
        kind: SchedulerRejectionKind.filterMissing,
        chip: 'Filter missing',
        summary: 'required filter not in wheel',
        curedByRising: false,
      ),
      6: (
        sentence: 'outside time window 2:00-4:00',
        kind: SchedulerRejectionKind.outsideTimeWindow,
        chip: 'Outside window',
        summary: 'outside time window 2:00-4:00',
        curedByRising: false,
      ),
      7: (
        sentence: 'moon illumination 2% exceeds max 0%',
        kind: SchedulerRejectionKind.moonIllumination,
        chip: 'Moon too bright',
        summary: 'moon illumination 2% exceeds max 0%',
        curedByRising: false,
      ),
      8: (
        sentence: 'moon separation 82° below minimum 179° (moon 2% lit)',
        kind: SchedulerRejectionKind.moonSeparation,
        chip: 'Too close to moon',
        summary: 'moon separation 82° below minimum 179° (moon 2% lit)',
        curedByRising: false,
      ),
      9: (
        sentence: 'horizon profile 42 not loaded (orchestrator bug)',
        kind: SchedulerRejectionKind.behindHorizonProfile,
        chip: 'Behind horizon',
        summary: 'behind custom horizon',
        curedByRising: true,
      ),
      10: (
        sentence:
            'altitude 44.9° below horizon profile "Oak" (89.0° at az 360°)',
        kind: SchedulerRejectionKind.behindHorizonProfile,
        chip: 'Behind horizon',
        summary: 'behind custom horizon',
        curedByRising: true,
      ),
    };
    for (final MapEntry(key: id, value: row) in expected.entries) {
      expect(_rowFor(decision, id), row, reason: 'T$id');
    }

    // A linked client reads the decision from the host's JSON. The sentences
    // stay on the wire under their old key; a host from before the kinds
    // sends only those, and they read as the same kinds.
    final wire = decision.toJson();
    expect(SchedulerDecision.fromJson(wire), decision);
    final legacy = SchedulerDecision.fromJson({
      ...wire,
      'scoredCandidates': [
        for (final s in wire['scoredCandidates'] as List)
          Map<String, dynamic>.from(s as Map)..remove('rejections'),
      ],
    });
    for (final MapEntry(key: id, value: row) in expected.entries) {
      expect(_rowFor(legacy, id), row, reason: 'T$id from an older host');
      expect(
        legacy.scoredCandidates
            .firstWhere((s) => s.targetId == id)
            .toJson()['rejectionReasons'],
        [row.sentence],
      );
    }
  });

  test('the Sun above the darkness limit', () async {
    final decision = await _decide([_candidate(1)], clock: _day);
    expect(_rowFor(decision, 1), (
      sentence: 'Sun 59.3° above darkness limit -12.0°: too bright to image',
      kind: SchedulerRejectionKind.other,
      chip: 'Rejected',
      summary: 'Sun 59.3° above darkness limit -12.0°: too bright to image',
      curedByRising: true,
    ));
  });

  test('the site horizon in the target direction', () async {
    final decision = await _decide(
      [_candidate(1)],
      site: SchedulerSite(
        latitudeDegrees: 45.0,
        longitudeDegrees: 21.0,
        localOffset: const Duration(hours: 2),
        horizon: SiteHorizonProfile.fromSamples(const [
          (azimuth: 0, altitude: 89),
          (azimuth: 90, altitude: 89),
          (azimuth: 180, altitude: 89),
          (azimuth: 270, altitude: 89),
        ]),
      ),
    );
    expect(_rowFor(decision, 1), (
      sentence:
          'altitude 44.9° below horizon profile "Site horizon" '
          '(89.0° at az 360°)',
      kind: SchedulerRejectionKind.behindHorizonProfile,
      chip: 'Behind horizon',
      summary: 'behind custom horizon',
      curedByRising: true,
    ));
  });

  // The sign that separates "below the horizon" from "too low" is the one
  // the sentence prints: a target at -0.04 deg reads -0.0, too low.
  test('an altitude that prints as -0.0 is too low, not below the '
      'horizon', () async {
    const ra = 21.42;
    var lo = -80.0;
    var hi = -35.0;
    double altAt(double dec) => AstronomyCalculations.objectAltAz(
      raDeg: ra * 15.0,
      decDeg: dec,
      dt: _night(),
      latitudeDeg: _site.latitudeDegrees,
      longitudeDeg: _site.longitudeDegrees,
    ).$1;
    for (var i = 0; i < 80; i++) {
      final mid = (lo + hi) / 2;
      if (altAt(mid) < -0.02) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final alt = altAt(hi);
    expect(alt, inInclusiveRange(-0.049, -0.001));
    final decision = await _decide([
      _candidate(1, raHours: ra, decDegrees: hi),
    ]);
    expect(_rowFor(decision, 1), (
      sentence: 'altitude -0.0° below site minimum 30.0°',
      kind: SchedulerRejectionKind.tooLowForSite,
      chip: 'Too low',
      summary: 'too low (-0.0° < site minimum 30.0°)',
      curedByRising: true,
    ));
  });
}
