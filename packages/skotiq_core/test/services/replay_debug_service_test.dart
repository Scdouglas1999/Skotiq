import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('ReplayDebugService', () {
    late SkotiqDatabase db;
    late ReplayDebugService service;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      service = ReplayDebugService(db);
    });

    tearDown(() async {
      await service.dispose();
      await db.close();
    });

    test('persist + listByRun round-trips every column', () async {
      final original = ReplayDecision(
        id: null,
        sequenceRunId: 42,
        timestamp: DateTime.utc(2026, 5, 17, 21, 30, 15),
        category: DecisionCategory.schedulerPick,
        summary: 'Picked M27 (78/100)',
        details: {
          'picked_target_id': 'm27',
          'picked_score': 78.0,
          'scores': [
            {'target_id': 'm27', 'total_score': 78.0, 'runnable': true},
            {'target_id': 'm51', 'total_score': 42.0, 'runnable': false},
          ],
        },
        nodeId: 'scheduler-1',
      );
      final id = await service.persist(original);
      expect(id, greaterThan(0));

      final loaded = await service.listByRun(42);
      expect(loaded, hasLength(1));
      final r = loaded.single;
      expect(r.id, id);
      expect(r.sequenceRunId, 42);
      expect(r.category, DecisionCategory.schedulerPick);
      expect(r.summary, 'Picked M27 (78/100)');
      expect(r.nodeId, 'scheduler-1');
      expect(r.details['picked_target_id'], 'm27');
      expect(r.details['picked_score'], 78.0);
      expect(r.details['scores'], isA<List<dynamic>>());
      // Timestamp survives the millisecond-resolution round-trip.
      expect(
        r.timestamp.toUtc().millisecondsSinceEpoch,
        original.timestamp.toUtc().millisecondsSinceEpoch,
      );
    });

    test('every DecisionCategory persists + reads back via wire_key', () async {
      const runId = 99;
      for (final cat in DecisionCategory.values.where(
        (c) => c != DecisionCategory.unknown,
      )) {
        await service.persist(
          ReplayDecision(
            id: null,
            sequenceRunId: runId,
            timestamp: DateTime.now().toUtc(),
            category: cat,
            summary: 'test ${cat.wireKey}',
            details: const {},
            nodeId: null,
          ),
        );
      }
      final all = await service.listByRun(runId);
      final cats = all.map((d) => d.category).toSet();
      // Every variant except `unknown` must round-trip.
      for (final cat in DecisionCategory.values.where(
        (c) => c != DecisionCategory.unknown,
      )) {
        expect(cats.contains(cat), isTrue, reason: 'missing ${cat.wireKey}');
      }
    });

    test('listByRun orders chronologically (ascending by timestamp)', () async {
      const runId = 7;
      final t0 = DateTime.utc(2026, 5, 17, 21, 0, 0);
      await service.persist(
        _decision(runId, t0.add(const Duration(seconds: 30)), summary: 'third'),
      );
      await service.persist(_decision(runId, t0, summary: 'first'));
      await service.persist(
        _decision(
          runId,
          t0.add(const Duration(seconds: 10)),
          summary: 'second',
        ),
      );

      final loaded = await service.listByRun(runId);
      expect(loaded.map((d) => d.summary).toList(), [
        'first',
        'second',
        'third',
      ]);
    });

    test('listByRunAndCategory filters server-side', () async {
      const runId = 8;
      final t = DateTime.utc(2026, 5, 17, 21, 0, 0);
      await service.persist(
        _decision(
          runId,
          t,
          category: DecisionCategory.frameAccepted,
          summary: 'accept',
        ),
      );
      await service.persist(
        _decision(
          runId,
          t.add(const Duration(seconds: 1)),
          category: DecisionCategory.frameRejected,
          summary: 'reject1',
        ),
      );
      await service.persist(
        _decision(
          runId,
          t.add(const Duration(seconds: 2)),
          category: DecisionCategory.frameRejected,
          summary: 'reject2',
        ),
      );
      await service.persist(
        _decision(
          runId,
          t.add(const Duration(seconds: 3)),
          category: DecisionCategory.recoveryEntered,
          summary: 'recovery',
        ),
      );

      final rejects = await service.listByRunAndCategory(
        runId,
        DecisionCategory.frameRejected,
      );
      expect(rejects, hasLength(2));
      expect(rejects.map((d) => d.summary).toList(), ['reject1', 'reject2']);
    });

    test('deleteForRun wipes only the targeted run', () async {
      final t = DateTime.utc(2026, 5, 17, 21, 0, 0);
      await service.persist(_decision(1, t, summary: 'run1-a'));
      await service.persist(_decision(2, t, summary: 'run2-a'));
      await service.persist(
        _decision(1, t.add(const Duration(seconds: 1)), summary: 'run1-b'),
      );

      final removed = await service.deleteForRun(1);
      expect(removed, 2);

      expect(await service.listByRun(1), isEmpty);
      expect(await service.listByRun(2), hasLength(1));
    });

    test('pruneOlderThan deletes only stale rows', () async {
      const runId = 5;
      final now = DateTime.utc(2026, 5, 17, 22, 0, 0);
      // 91 days ago — should be pruned at 90-day retention.
      await service.persist(
        _decision(
          runId,
          now.subtract(const Duration(days: 91)),
          summary: 'old',
        ),
      );
      // 1 day ago — should survive.
      await service.persist(
        _decision(
          runId,
          now.subtract(const Duration(days: 1)),
          summary: 'recent',
        ),
      );

      final cutoff = now.subtract(const Duration(days: 90));
      final removed = await service.pruneOlderThan(cutoff);
      expect(removed, 1);

      final remaining = await service.listByRun(runId);
      expect(remaining, hasLength(1));
      expect(remaining.single.summary, 'recent');
    });

    test('persistFromBridgeEvent decodes the JSON payload', () async {
      final id = await service.persistFromBridgeEvent(
        timestampIso: '2026-05-17T21:30:00Z',
        categoryWireKey: 'trigger_fired',
        summary: 'HFR drift trigger fired',
        detailsJson:
            '{"trigger_id":"hfr-1","trigger_name":"HFR Drift","action":"Autofocus"}',
        nodeId: 'expose-3',
        sequenceRunId: 17,
      );
      expect(id, greaterThan(0));
      final loaded = await service.listByRun(17);
      expect(loaded.single.category, DecisionCategory.triggerFired);
      expect(loaded.single.details['trigger_name'], 'HFR Drift');
      expect(loaded.single.nodeId, 'expose-3');
    });

    test('countByRun returns the persisted count', () async {
      final t = DateTime.utc(2026, 5, 17, 21, 0, 0);
      for (var i = 0; i < 5; i++) {
        await service.persist(
          _decision(33, t.add(Duration(seconds: i)), summary: 'd$i'),
        );
      }
      expect(await service.countByRun(33), 5);
      expect(await service.countByRun(34), 0);
    });

    test('watchByRun emits initial snapshot + new rows', () async {
      const runId = 12;
      final emissions = <List<ReplayDecision>>[];
      final sub = service.watchByRun(runId).listen(emissions.add);

      // Let the initial yield complete.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(emissions, hasLength(1));
      expect(emissions.first, isEmpty);

      await service.persist(
        _decision(runId, DateTime.utc(2026, 5, 17, 21), summary: 'first'),
      );

      // Wait for the change-bus notification to bubble through.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(
        emissions.length,
        greaterThanOrEqualTo(2),
        reason: 'watchByRun must emit on mutation',
      );
      expect(emissions.last.map((d) => d.summary).toList(), ['first']);

      await sub.cancel();
    });
  });

  group('ReplayDecision.fromBridgeEvent', () {
    test('parses well-formed JSON details', () {
      final d = ReplayDecision.fromBridgeEvent(
        timestampIso: '2026-05-17T22:00:00Z',
        categoryWireKey: 'frame_rejected',
        summary: 'frame 5/10 REJECTED: cloud',
        detailsJson:
            '{"frame":5,"total":10,"reason":"cloud","reject_path":"/x/Reject/abc.fits"}',
      );
      expect(d.category, DecisionCategory.frameRejected);
      expect(d.details['reject_path'], '/x/Reject/abc.fits');
      expect(d.details['frame'], 5);
    });

    test('malformed JSON details yields a synthetic parse-error map', () {
      final d = ReplayDecision.fromBridgeEvent(
        timestampIso: '2026-05-17T22:00:00Z',
        categoryWireKey: 'system_event',
        summary: 'bad',
        detailsJson: '{not valid json',
      );
      expect(d.details['__parse_error'], 'malformed JSON');
      expect(d.details['__raw'], '{not valid json');
    });

    test('unknown category key falls back to DecisionCategory.unknown', () {
      final d = ReplayDecision.fromBridgeEvent(
        timestampIso: '2026-05-17T22:00:00Z',
        categoryWireKey: 'brand_new_variant_dart_does_not_know_yet',
        summary: 'future-proof',
        detailsJson: '{}',
      );
      expect(d.category, DecisionCategory.unknown);
    });
  });
}

ReplayDecision _decision(
  int runId,
  DateTime ts, {
  DecisionCategory category = DecisionCategory.systemEvent,
  String summary = 'test',
  Map<String, dynamic> details = const {},
  String? nodeId,
}) => ReplayDecision(
  id: null,
  sequenceRunId: runId,
  timestamp: ts,
  category: category,
  summary: summary,
  details: details,
  nodeId: nodeId,
);
