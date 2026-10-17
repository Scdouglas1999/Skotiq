import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart'
    show standaloneImagesProvider;
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _SelectionNotifier extends SciencePhotometrySelectionNotifier {
  @override
  Future<SciencePhotometrySelection> build() async =>
      const SciencePhotometrySelection();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'session-index failure is retryable and never masquerades as standalone mode',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      var sessionAttempts = 0;
      var standaloneScienceBuilds = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            allSessionsProvider.overrideWith((ref) {
              sessionAttempts++;
              return Stream<List<ImagingSession>>.error(
                StateError('session index unavailable'),
              );
            }),
            sessionlessPhotometryProvider.overrideWith((ref) {
              standaloneScienceBuilds++;
              return Stream.value(const <PhotometryMeasurementRow>[]);
            }),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: ScienceAnalyticsTab()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Could not load imaging sessions'), findsOneWidget);
      expect(
        find.textContaining('Bad state: session index unavailable'),
        findsOneWidget,
      );
      expect(standaloneScienceBuilds, 0);
      expect(sessionAttempts, 1);

      await tester.tap(find.widgetWithText(SkotiqButton, 'Retry'));
      await tester.pumpAndSettle();
      expect(sessionAttempts, 2);
      expect(standaloneScienceBuilds, 0);
    },
  );

  testWidgets('science-product failure replaces the false empty-state onramp',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    var photometryAttempts = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          allSessionsProvider.overrideWith(
            (ref) => Stream.value(const <ImagingSession>[]),
          ),
          sessionlessPhotometryProvider.overrideWith((ref) {
            photometryAttempts++;
            return Stream<List<PhotometryMeasurementRow>>.error(
              StateError('photometry store unavailable'),
            );
          }),
          sessionlessTransparencySamplesProvider.overrideWith(
            (ref) => Stream.value(const <TransparencySampleRow>[]),
          ),
          sessionlessCalibrationsProvider.overrideWith(
            (ref) => Stream.value(const <FramePhotometricCalibrationRow>[]),
          ),
          sessionlessPsfTilesProvider.overrideWith(
            (ref) => Stream.value(const <PsfFieldTileRow>[]),
          ),
          sessionlessResidualVectorsProvider.overrideWith(
            (ref) => Stream.value(const <AstrometryResidualVectorRow>[]),
          ),
          sessionlessMovingObjectCandidatesProvider.overrideWith(
            (ref) => Stream.value(const <MovingObjectCandidateRow>[]),
          ),
          sessionlessLineRatioProductsProvider.overrideWith(
            (ref) => Stream.value(const <LineRatioProductRow>[]),
          ),
          sessionlessFrameQualityMetricsProvider.overrideWith(
            (ref) => Stream.value(const <ScienceFrameQualityMetricsRow>[]),
          ),
          sessionlessTileMetricsProvider.overrideWith(
            (ref) => Stream.value(const <ScienceTileMetricRow>[]),
          ),
          standaloneImagesProvider.overrideWith(
            (ref) => Stream.value(const <DbCapturedImage>[]),
          ),
          sciencePhotometrySelectionProvider.overrideWith(
            _SelectionNotifier.new,
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: ScienceAnalyticsTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Some science data could not be loaded'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Bad state: photometry store unavailable'),
      findsOneWidget,
    );
    expect(photometryAttempts, 1);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(photometryAttempts, 2);
  });
}
