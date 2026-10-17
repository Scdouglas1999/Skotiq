// Analytics > History's target filter must filter by TARGET.
//
// Observed defect: the dropdown labelled "All Targets" was populated with
// `select distinct name from imaging_sessions` — sequence names. The one row in
// `targets` ("M81") never appeared in it, and selecting an entry filtered by
// session name, so a user with three targets across forty nights could not
// filter their history by target at all.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

ImagingSession _session({
  required int id,
  required String name,
  int? targetId,
}) {
  return ImagingSession(
    id: id,
    name: name,
    startTime: DateTime.utc(2026, 7, 25, 17, id),
    totalExposures: 0,
    successfulExposures: 0,
    failedExposures: 0,
    totalIntegrationSecs: 0,
    autofocusCount: 0,
    status: 'completed',
    targetId: targetId,
  );
}

DbTarget _target({required int id, required String name}) {
  return DbTarget(
    id: id,
    name: name,
    ra: 9.9,
    dec: 69.0,
    minAltitude: 30,
    priority: 0,
    totalPlannedSubs: 0,
    capturedSubs: 0,
    totalIntegrationSecs: 0,
    goalIntegrationSecs: 0,
    createdAt: DateTime.utc(2026, 7, 1),
    updatedAt: DateTime.utc(2026, 7, 1),
    isFavorite: false,
  );
}

void main() {
  late ProviderContainer container;

  // Two sequences pointed at M81, one calibration run with no target at all —
  // the shape the audit found in the live database.
  final sessions = [
    _session(id: 1, name: 'Audit Session M42', targetId: 1),
    _session(id: 2, name: 'CLAUDE AF TEST', targetId: 1),
    _session(id: 3, name: 'MF PROBE A (dark baseline)'),
  ];
  final targets = [
    _target(id: 1, name: 'M81'),
    // A catalogued target with no sessions must not clutter the filter.
    _target(id: 2, name: 'NGC 7000'),
  ];

  setUp(() {
    container = ProviderContainer(overrides: [
      inMemoryDatabaseOverride(),
      allSessionsProvider.overrideWith((ref) => Stream.value(sessions)),
      allDbTargetsProvider.overrideWith((ref) => Stream.value(targets)),
    ]);
    addTearDown(container.dispose);
  });

  test('filter options are real target names, not session names', () async {
    // Prime both streams.
    await container.read(allSessionsProvider.future);
    await container.read(allDbTargetsProvider.future);

    final options = container.read(sessionTargetNamesProvider).valueOrNull;
    expect(options, isNotNull);
    expect(options!.first, kAllTargetsFilter);
    // The real target that the sessions reference is offered…
    expect(options, contains('M81'));
    // …the sessions with no target get their own bucket…
    expect(options, contains(kUntargetedSessionsFilter));
    // …and no sequence name is masquerading as a target.
    expect(options, isNot(contains('Audit Session M42')));
    expect(options, isNot(contains('CLAUDE AF TEST')));
    // A target with no recorded sessions would filter to nothing, so it is not
    // offered.
    expect(options, isNot(contains('NGC 7000')));
  });

  test('selecting a target matches by targetId, not by session name', () {
    final byId = {for (final t in targets) t.id: t.name};

    final matched = sessions
        .where((s) => sessionMatchesTargetFilter(s, 'M81', byId))
        .map((s) => s.id)
        .toList();
    expect(matched, [1, 2]);

    final untargeted = sessions
        .where(
          (s) => sessionMatchesTargetFilter(s, kUntargetedSessionsFilter, byId),
        )
        .map((s) => s.id)
        .toList();
    expect(untargeted, [3]);

    final all = sessions
        .where((s) => sessionMatchesTargetFilter(s, kAllTargetsFilter, byId))
        .length;
    expect(all, sessions.length);

    // The filter matches TARGET names, never the session's own name.
    expect(
      sessions.any(
        (s) => sessionMatchesTargetFilter(s, 'Audit Session M42', byId),
      ),
      isFalse,
    );
  });
}
