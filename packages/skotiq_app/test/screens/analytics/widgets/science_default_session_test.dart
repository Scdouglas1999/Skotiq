// The Science tab must open on a night that has science on it.
//
// Observed: after adding a 2-frame session (Night E — M13, no photometry, no
// solves) that started later than a 120-frame photometry night, the Science tab
// opened on Night E and showed "0% — 0 of 2 solved", "Warming up" and the
// empty-state "Turn pretty pictures into real measurements". The calibrated
// night was two clicks away in a dropdown.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart'
    show dbSessionImagesProvider;
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _StubImagesDao extends Mock implements ImagesDao {}

class _StubScienceDao extends Mock implements ScienceDao {}

ImagingSession _session(int id, String name, DateTime start) => ImagingSession(
      id: id,
      name: name,
      startTime: start,
      totalExposures: 0,
      successfulExposures: 0,
      failedExposures: 0,
      totalIntegrationSecs: 0,
      autofocusCount: 0,
      status: 'completed',
    );

/// Newest first, the way the session picker beside the tab orders them.
final _sessions = [
  _session(5, 'Night E — M13', DateTime.utc(2026, 8, 2, 3)),
  _session(4, 'Night D — photometry', DateTime.utc(2026, 8, 1, 3)),
  _session(3, 'Night C — darks', DateTime.utc(2026, 7, 31, 3)),
];

ProviderContainer _container({
  required Set<int> withPhotometry,
  required Set<int> withSolves,
  List<ImagingSession> sessions = const [],
}) {
  final images = _StubImagesDao();
  final science = _StubScienceDao();
  when(images.getSessionIdsWithSolvedFrames)
      .thenAnswer((_) async => withSolves);
  when(science.getSessionIdsWithPhotometry)
      .thenAnswer((_) async => withPhotometry);
  return ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      imagesDaoProvider.overrideWithValue(images),
      scienceDaoProvider.overrideWithValue(science),
      allSessionsProvider.overrideWith((ref) => Stream.value(sessions)),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('two test frames do not bury the photometry night they follow',
      () async {
    final container = _container(
      withPhotometry: {4},
      withSolves: {4},
      sessions: _sessions,
    );
    addTearDown(container.dispose);

    expect(
      await container.read(latestScienceProductSessionProvider.future),
      4,
      reason: 'session 5 is newer but has no science product at all',
    );
  });

  test('a solve alone is enough, without photometry', () async {
    final container = _container(
      withPhotometry: const {},
      withSolves: {3},
      sessions: _sessions,
    );
    addTearDown(container.dispose);

    expect(await container.read(latestScienceProductSessionProvider.future), 3);
  });

  test('the newest qualifying session wins, not merely any of them', () async {
    final container = _container(
      withPhotometry: {3},
      withSolves: {5},
      sessions: _sessions,
    );
    addTearDown(container.dispose);

    expect(
      await container.read(latestScienceProductSessionProvider.future),
      5,
      reason: '"most recent" has to mean the same thing here as in the picker',
    );
  });

  test('with no science anywhere it defers to the older fallbacks', () async {
    final container = _container(
      withPhotometry: const {},
      withSolves: const {},
      sessions: _sessions,
    );
    addTearDown(container.dispose);

    expect(
      await container.read(latestScienceProductSessionProvider.future),
      isNull,
      reason: 'null lets the caller fall through to the newest session with '
          'light frames, then to the newest session at all',
    );
  });

  // The four tests above only prove the provider answers correctly. They all
  // stay green with the `latestScienceProductSessionProvider` line deleted from
  // the tab's own session resolution — i.e. with the production wiring removed.
  // This one pumps the real tab and watches which session it actually loads
  // science for, so it goes red the moment that line goes away.
  testWidgets('the tab itself analyses the science-product session',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final analysed = <int>[];
    await tester.pumpWidget(_tab(analysed));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // `analysed.last`, not `contains`: both session-id providers are async, so
    // the very first frame legitimately falls all the way through to
    // `allSessions.first` (5) before either resolves. What the operator is left
    // looking at is the settled choice.
    expect(
      analysed.last,
      4,
      reason: 'session 5 is the newest holding light frames, but 4 is the '
          'newest carrying a science product — the tab has to settle on 4 or '
          'the operator lands on the never-started empty state again',
    );
  });
}

/// The Science tab wired the way it ships, with only its data sources stubbed.
/// `latestScienceSessionProvider` deliberately answers a DIFFERENT (newer)
/// session than `latestScienceProductSessionProvider` so the two rules cannot
/// both be satisfied by accident, and every session-keyed query records the id
/// the tab asked for — the tab's choice, observed at the production call site
/// rather than at the provider it is supposed to consult.
Widget _tab(List<int> analysed) => ProviderScope(
      overrides: [
        allSessionsProvider.overrideWith((ref) => Stream.value(_sessions)),
        latestScienceProductSessionProvider.overrideWith((ref) async => 4),
        latestScienceSessionProvider.overrideWith((ref) async => 5),
        sessionPhotometryProvider.overrideWith((ref, id) {
          analysed.add(id);
          return Stream.value(_curve(id));
        }),
        sessionTransparencySamplesProvider.overrideWith(
          (ref, id) => Stream.value(const <TransparencySampleRow>[]),
        ),
        sessionFrameCalibrationsProvider.overrideWith(
          (ref, id) => Stream.value(const <FramePhotometricCalibrationRow>[]),
        ),
        sessionPsfTilesProvider.overrideWith(
          (ref, id) => Stream.value(const <PsfFieldTileRow>[]),
        ),
        sessionResidualVectorsProvider.overrideWith(
          (ref, id) => Stream.value(const <AstrometryResidualVectorRow>[]),
        ),
        sessionMovingObjectCandidatesProvider.overrideWith(
          (ref, id) => Stream.value(const <MovingObjectCandidateRow>[]),
        ),
        sessionLineRatioProductsProvider.overrideWith(
          (ref, id) => Stream.value(const <LineRatioProductRow>[]),
        ),
        sessionFrameQualityMetricsProvider.overrideWith(
          (ref, id) => Stream.value(const <ScienceFrameQualityMetricsRow>[]),
        ),
        sessionTileMetricsProvider.overrideWith(
          (ref, id) => Stream.value(const <ScienceTileMetricRow>[]),
        ),
        dbSessionImagesProvider.overrideWith(
          (ref, id) => Stream.value(const <DbCapturedImage>[]),
        ),
        sciencePhotometrySelectionProvider
            .overrideWith(_NoSelectionNotifier.new),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: ScienceAnalyticsTab()),
      ),
    );

List<PhotometryMeasurementRow> _curve(int sessionId) => [
      for (var i = 0; i < 20; i++)
        PhotometryMeasurementRow(
          id: sessionId * 100 + i,
          sessionId: sessionId,
          objectId: 'V-TEST',
          role: 'target',
          x: 512,
          y: 512,
          flux: 10000 + i * 10,
          differentialMagnitude: -0.30 + i * 0.03,
          snr: 80,
          uncertainty: 0.01,
          isOutlier: false,
          timestamp: DateTime.utc(2026, 8, sessionId, 21, i),
        ),
    ];

class _NoSelectionNotifier extends SciencePhotometrySelectionNotifier {
  @override
  Future<SciencePhotometrySelection> build() async =>
      const SciencePhotometrySelection();
}
