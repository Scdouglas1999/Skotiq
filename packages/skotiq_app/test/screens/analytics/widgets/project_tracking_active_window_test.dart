// The Projects header's activity tile counted targets whose last session fell
// after the 1st of the calendar month. On Aug 1, a run on Jul 25/28/30 — three
// nights ago — reported "0 Active This Month". The window is now a rolling 30
// nights and the label says so.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/project_tracking_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Fixed "now" so the calendar-month boundary sits in a known place.
class _FrozenClock implements Clock {
  final DateTime _now;
  _FrozenClock(this._now);

  @override
  DateTime now() => _now;

  @override
  DateTime nowUtc() => _now.toUtc();

  @override
  Duration get utcOffset => Duration.zero;

  @override
  DateTime fromUtc(DateTime utc) => utc;
}

ProjectProgress _project(int id, String name, DateTime lastSessionAt) {
  final created = DateTime(2026, 1, 1);
  return ProjectProgress(
    target: DbTarget(
      id: id,
      name: name,
      ra: 0.71,
      dec: 41.27,
      minAltitude: 20,
      priority: 1,
      totalPlannedSubs: 0,
      capturedSubs: 0,
      totalIntegrationSecs: 0,
      goalIntegrationSecs: 3600,
      createdAt: created,
      updatedAt: created,
      isFavorite: false,
    ),
    sessionCount: 1,
    successfulExposures: 0,
    integratedSecs: 0,
    lastSessionAt: lastSessionAt,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('targets imaged days ago still count across a month boundary',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // The day the finding was filed: three nights of imaging sat in the
          // previous calendar month.
          clockProvider.overrideWithValue(_FrozenClock(DateTime(2026, 8, 1))),
          projectProgressListProvider.overrideWith(
            (ref) => AsyncValue.data([
              _project(1, 'M31', DateTime(2026, 7, 25)),
              _project(2, 'M42', DateTime(2026, 7, 28)),
              _project(3, 'M13', DateTime(2026, 7, 30)),
              // Last imaged in the spring — outside the 30-night window.
              _project(4, 'NGC 7000', DateTime(2026, 5, 2)),
            ]),
          ),
          perFilterIntegrationProvider.overrideWith(
            (ref) => const AsyncValue.data(<int, Map<String, double>>{}),
          ),
          untrackedTargetsCountProvider.overrideWith((ref) async => 0),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SizedBox(
              width: 1200,
              height: 900,
              child: ProjectTrackingPanel(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final label = find.text('Active (30d)');
    expect(label, findsOneWidget);
    final tile = find.ancestor(of: label, matching: find.byType(Column)).first;
    expect(
      find.descendant(of: tile, matching: find.text('3')),
      findsOneWidget,
      reason: 'three targets were imaged within the last 30 nights',
    );
  });
}
