import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart'
    show dbSessionImagesProvider;
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

class _ActiveSessionNotifier extends SessionStateNotifier {
  _ActiveSessionNotifier(super.ref) {
    state = const SessionState(dbSessionId: 42);
  }
}

class _ScienceSettingsNotifier extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async =>
      const ScienceSettings(narrowbandRatiosEnabled: true);
}

class _SelectionNotifier extends SciencePhotometrySelectionNotifier {
  @override
  Future<SciencePhotometrySelection> build() async =>
      const SciencePhotometrySelection();
}

LineRatioProductRow _existingProduct() => LineRatioProductRow(
      id: 1,
      sessionId: 42,
      ratioSiiHa: 0.5,
      ratioOiiiHa: 0.75,
      ratioSiiOiii: 0.66,
      createdAt: DateTime.utc(2026, 7, 14),
    );

void main() {
  testWidgets('line-ratio generation discards an old-host completion',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final oldHostCommand = Completer<Map<String, dynamic>>();
    late _SwappableBackendNotifier backendNotifier;
    when(() => hostA.generateSessionLineRatios(42))
        .thenAnswer((_) => oldHostCommand.future);
    when(() => hostB.generateSessionLineRatios(42)).thenAnswer(
      (_) async => {
        'files': ['host-b-ratios.fits'],
      },
    );

    final handle = await pumpAppScreen(
      tester,
      const ScienceAnalyticsTab(),
      size: const Size(1200, 900),
      settle: false,
      registerTearDown: false,
      extraOverrides: [
        backendProvider.overrideWith((ref) {
          backendNotifier = _SwappableBackendNotifier(ref, hostA);
          return backendNotifier;
        }),
        sessionStateProvider.overrideWith(_ActiveSessionNotifier.new),
        allSessionsProvider.overrideWith(
          (ref) => Stream.value(const <ImagingSession>[]),
        ),
        scienceSettingsProvider.overrideWith(_ScienceSettingsNotifier.new),
        sciencePhotometrySelectionProvider.overrideWith(
          _SelectionNotifier.new,
        ),
        sessionPhotometryProvider.overrideWith(
          (ref, sessionId) => Stream.value(const <PhotometryMeasurementRow>[]),
        ),
        sessionFrameCalibrationsProvider.overrideWith(
          (ref, sessionId) =>
              Stream.value(const <FramePhotometricCalibrationRow>[]),
        ),
        sessionTransparencySamplesProvider.overrideWith(
          (ref, sessionId) => Stream.value(const <TransparencySampleRow>[]),
        ),
        sessionPsfTilesProvider.overrideWith(
          (ref, sessionId) => Stream.value(const <PsfFieldTileRow>[]),
        ),
        sessionFrameQualityMetricsProvider.overrideWith(
          (ref, sessionId) =>
              Stream.value(const <ScienceFrameQualityMetricsRow>[]),
        ),
        sessionTileMetricsProvider.overrideWith(
          (ref, sessionId) => Stream.value(const <ScienceTileMetricRow>[]),
        ),
        sessionResidualVectorsProvider.overrideWith(
          (ref, sessionId) =>
              Stream.value(const <AstrometryResidualVectorRow>[]),
        ),
        sessionMovingObjectCandidatesProvider.overrideWith(
          (ref, sessionId) => Stream.value(const <MovingObjectCandidateRow>[]),
        ),
        sessionLineRatioProductsProvider.overrideWith(
          (ref, sessionId) => Stream.value([_existingProduct()]),
        ),
        dbSessionImagesProvider.overrideWith(
          (ref, sessionId) => Stream.value(const <DbCapturedImage>[]),
        ),
      ],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    var generateButton = find.widgetWithText(
      SkotiqButton,
      'Generate From Session Frames',
    );
    expect(generateButton, findsOneWidget);
    await tester.ensureVisible(generateButton);
    await tester.tap(generateButton);
    await tester.pump();
    expect(find.text('Generating...'), findsOneWidget);

    backendNotifier.switchTo(hostB);
    await tester.pump();
    expect(
      find.widgetWithText(SkotiqButton, 'Generate From Session Frames'),
      findsOneWidget,
    );

    oldHostCommand.complete({
      'files': ['host-a-ratios.fits'],
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('host-a-ratios.fits'), findsNothing);

    generateButton = find.widgetWithText(
      SkotiqButton,
      'Generate From Session Frames',
    );
    await tester.ensureVisible(generateButton);
    await tester.tap(generateButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    verify(() => hostA.generateSessionLineRatios(42)).called(1);
    verify(() => hostB.generateSessionLineRatios(42)).called(1);
    expect(find.text('Generated using host-b-ratios.fits.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    handle.container.dispose();
    await handle.database.close();
  });
}
