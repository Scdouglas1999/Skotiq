// Settings > Location lists the obstructions runs learned at this site, with a
// remove per point and a confirmed clear, and says so when there are none.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/learned_obstructions_section.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this.initial);

  final AppSettingsState initial;

  @override
  Future<AppSettingsState> build() async => initial;
}

LearnedObstructionPoint _point(double az, double alt, {double lat = 43.1}) =>
    LearnedObstructionPoint(
      azimuthDeg: az,
      altitudeDeg: alt,
      latitude: lat,
      longitude: -77.6,
      recordedAt: DateTime(2026, 10, 24, 3, 28),
      targetName: 'NGC 891',
    );

Future<HarnessHandle> _pump(
  WidgetTester tester,
  List<LearnedObstructionPoint> points, {
  bool siteSet = true,
}) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  if (points.isNotEmpty) {
    await tester.runAsync(
      () => db.settingsDao.setSetting(
        learnedHorizonPointsKey,
        encodeLearnedObstructionPoints(points),
      ),
    );
  }
  final handle = await pumpAppScreen(
    tester,
    const SingleChildScrollView(child: LearnedObstructionsSection()),
    size: const Size(900, 900),
    database: db,
    extraOverrides: [
      appSettingsProvider.overrideWith(
        () => _StubAppSettingsNotifier(
          siteSet
              ? const AppSettingsState(latitude: 43.1, longitude: -77.6)
              : const AppSettingsState(),
        ),
      ),
    ],
  );
  await tester.pumpAndSettle();
  return handle;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('says so when nothing was learned here', (tester) async {
    // A point from another site does not show.
    await _pump(tester, [_point(120, 30, lat: 10)]);
    expect(find.text('LEARNED OBSTRUCTIONS'), findsOneWidget);
    expect(find.text('No obstructions learned at this site yet.'), findsOne);
    expect(find.text('Clear all'), findsNothing);
  });

  testWidgets('asks for the site when none is set', (tester) async {
    await _pump(tester, [_point(286.2, 64)], siteSet: false);
    expect(
      find.text('Set the site location to see the obstructions learned here.'),
      findsOneWidget,
    );
  });

  testWidgets('lists this site\'s points by azimuth with date and target', (
    tester,
  ) async {
    await _pump(tester, [_point(286.2, 64), _point(95.5, 22.25)]);
    final first = tester.getTopLeft(find.text('Az 95.5°, alt 22.3°'));
    final second = tester.getTopLeft(
      find.text('Az 286.2°, alt 64.0°'),
    );
    expect(first.dy, lessThan(second.dy));
    expect(find.text('NGC 891, 2026-10-24'), findsNWidgets(2));
    expect(find.text('Remove'), findsNWidgets(2));
  });

  testWidgets('removes one point', (tester) async {
    final handle = await _pump(tester, [_point(286.2, 64), _point(95.5, 22)]);
    await tester.tap(find.text('Remove').first);
    await tester.pumpAndSettle();
    expect(find.text('Az 95.5°, alt 22.0°'), findsNothing);
    expect(find.text('Az 286.2°, alt 64.0°'), findsOneWidget);
    final stored = handle.container
        .read(frameWatchSettingsProvider)
        .requireValue
        .learnedPoints;
    expect(stored.single.azimuthDeg, 286.2);
  });

  testWidgets('clear all asks first and keeps other sites', (tester) async {
    final handle = await _pump(tester, [
      _point(286.2, 64),
      _point(95.5, 22),
      _point(120, 30, lat: 10),
    ]);
    await tester.tap(find.text('Clear all'));
    await tester.pumpAndSettle();
    expect(find.text('Clear learned obstructions?'), findsOneWidget);

    // Canceling keeps everything.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Remove'), findsNWidgets(2));

    await tester.tap(find.text('Clear all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear all').last);
    await tester.pumpAndSettle();
    expect(find.text('No obstructions learned at this site yet.'), findsOne);
    final stored = handle.container
        .read(frameWatchSettingsProvider)
        .requireValue
        .learnedPoints;
    expect(stored.single.latitude, 10);
  });
}
