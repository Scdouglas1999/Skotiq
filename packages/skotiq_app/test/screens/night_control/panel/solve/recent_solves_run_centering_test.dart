// A run's Center steps solve and correct on the host's executor, which the
// app sees only as the step's progress events. Tonight's Solve tab listed the
// operator's own solves and centerings and none of the run's.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/panel/solve/recent_solves_provider.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../../harness/mock_backend.dart';
import '../../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

SkotiqEvent _center(
  String nodeId, {
  required int attempt,
  double? separation,
  (double, double)? solvedAt,
}) =>
    SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: EventSeverity.info,
      category: EventCategory.sequencer,
      eventType: 'InstructionProgressStructured',
      data: {
        'node_id': nodeId,
        'instruction': 'Center',
        'progress_percent': 50.0,
        'detail_kind': 'Center',
        'detail_json': jsonEncode({
          'attempt': attempt,
          'max_attempts': 3,
          'last_separation_arcsec': separation,
          'solved_ra_hours': solvedAt?.$1,
          'solved_dec_degrees': solvedAt?.$2,
        }),
      },
    );

SkotiqEvent _completed(String nodeId, String status) => SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: EventSeverity.info,
      category: EventCategory.sequencer,
      eventType: 'NodeCompleted',
      data: {'node_id': nodeId, 'status': status},
    );

Future<List<NightSolveRecord>> _recordsAfter(List<SkotiqEvent> events) async {
  final backend = mockBackend();
  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    backendProvider.overrideWith((ref) => _TestBackendNotifier(ref, backend)),
  ]);
  addTearDown(container.dispose);
  container.read(nightRecentSolvesProvider);
  events.forEach(backend.emitEvent);
  await Future<void>.delayed(Duration.zero);
  return container.read(nightRecentSolvesProvider);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a run that centers in two attempts lists both solves and the centering',
      () async {
    final records = await _recordsAfter([
      _center('center-1', attempt: 0),
      _center('center-1', attempt: 1),
      _center(
        'center-1',
        attempt: 1,
        separation: 182.4,
        solvedAt: (22.6, 40.05),
      ),
      // The correction slew of the same attempt repeats its distance.
      _center('center-1', attempt: 1, separation: 182.4),
      _center('center-1', attempt: 2),
      _center(
        'center-1',
        attempt: 2,
        separation: 6.1,
        solvedAt: (22.6, 40.0017),
      ),
      _center('center-1', attempt: 0, separation: 6.1),
      _center('center-1', attempt: 0, separation: 6.1),
      _completed('center-1', 'success'),
    ]);

    // Newest first.
    expect(records.map((r) => r.kind), [
      NightSolveKind.center,
      NightSolveKind.solve,
      NightSolveKind.solve,
    ]);
    expect(records[0].success, isTrue);
    expect(records[0].offsetArcsec, 6.1);
    expect(records[0].iterations, 2);
    expect(records[1].offsetArcsec, 6.1);
    expect(records[2].offsetArcsec, 182.4);
    expect(records.every((r) => r.success), isTrue);
    expect(records[2].raDegrees, closeTo(339.0, 1e-9));
    expect(records[2].decDegrees, 40.05);
    expect(records.every((r) => r.byRun), isTrue);
  });

  test('a Center step that ends without centering lists a failed centering',
      () async {
    final records = await _recordsAfter([
      _center('center-1', attempt: 1),
      _center('center-1', attempt: 1, separation: 900.0),
      _center('center-1', attempt: 2),
      _center('center-1', attempt: 2, separation: 640.0),
      _completed('center-1', 'skipped'),
    ]);

    expect(records.first.kind, NightSolveKind.center);
    expect(records.first.success, isFalse);
    expect(records.first.iterations, 2);
    expect(records.first.offsetArcsec, 640.0);
  });

  test('a stopped Center step is not listed as a failed centering', () async {
    final records = await _recordsAfter([
      _center('center-1', attempt: 1),
      _completed('center-1', 'cancelled'),
    ]);
    expect(records.where((r) => r.kind == NightSolveKind.center), isEmpty);
  });
}
