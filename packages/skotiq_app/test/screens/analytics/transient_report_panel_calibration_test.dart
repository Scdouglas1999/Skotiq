import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/transient_report_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _TestScienceSettingsNotifier extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async {
    return const ScienceSettings(aavsoObserverCode: 'ABC');
  }
}

int _settingsAttempts = 0;

class _FailingScienceSettingsNotifier extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async {
    _settingsAttempts++;
    throw StateError('report credentials unavailable');
  }
}

void main() {
  final now = DateTime.utc(2026, 7, 13);
  final detection = TransientDetectionRow(
    id: 9,
    sessionId: 3,
    capturedImageId: 44,
    tileId: 1,
    detectedAt: now,
    raDeg: 83.8,
    decDeg: -5.4,
    residualFlux: 1000,
    deltaMag: -0.5,
    snr: 12,
    fwhm: 2.1,
    eccentricity: 0.2,
    positionAngleDeg: 0,
    kind: 'newSource',
    catalogMatch: null,
    confidence: 0.95,
    reviewed: true,
    dismissed: false,
  );
  final calibration = FramePhotometricCalibrationRow(
    bandIsStandard: false,
    id: 7,
    capturedImageId: 44,
    sessionId: 3,
    isCalibrated: true,
    zeroPoint: 25.2,
    limitingMag3Sigma: 19,
    limitingMag5Sigma: 18.5,
    matchedStarCount: 30,
    calibrationRms: 0.03,
    catalogSource: 'Gaia DR3',
    solverId: 'test',
    timestamp: now,
  );

  testWidgets('AAVSO enables for the exact calibrated detection frame',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          scienceSettingsProvider
              .overrideWith(_TestScienceSettingsNotifier.new),
          sessionFrameCalibrationsProvider.overrideWith(
            (ref, sessionId) => Stream.value([calibration]),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: SingleChildScrollView(
              child: TransientReportPanel(
                colors: SkotiqColors.dark,
                detections: [detection],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final aavso = tester.widget<SkotiqChip>(
      find.widgetWithText(SkotiqChip, 'AAVSO'),
    );
    expect(aavso.onTap, isNotNull);

    await tester.tap(find.text('AAVSO'));
    await tester.pump();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Preview'));
    await tester.pump();

    expect(find.textContaining('25.2'), findsNothing,
        reason: 'The report contains calibrated magnitude, not raw zeropoint.');
    expect(find.textContaining('STD'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('report credentials outage blocks report actions and retries',
      (tester) async {
    _settingsAttempts = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          scienceSettingsProvider.overrideWith(
            _FailingScienceSettingsNotifier.new,
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: TransientReportPanel(
              colors: SkotiqColors.dark,
              detections: [detection],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Reporting settings unavailable'), findsOneWidget);
    expect(
      find.textContaining('Bad state: report credentials unavailable'),
      findsOneWidget,
    );
    expect(find.text('Submit to TNS'), findsNothing);
    expect(_settingsAttempts, 1);

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Retry reporting settings'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(_settingsAttempts, 2);
    expect(find.text('Submit to TNS'), findsNothing);
  });
}
