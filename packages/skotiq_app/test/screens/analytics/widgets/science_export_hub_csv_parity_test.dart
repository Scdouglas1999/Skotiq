// The exact bytes each science CSV export writes.
//
// The seven row builders in the export hub were near-identical copies of one
// five-step recipe, and collapsing them onto a single descriptor-driven builder
// is only safe if the output does not move: these files are a published format
// that ends up in other people's pipelines. This pins the header row AND the
// first data row of all seven datasets, character for character.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_export_hub.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

TestFlutterView get _view =>
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;

final _stamp = DateTime.utc(2026, 8, 1, 9);

/// One seeded row per dataset, in the order the hub lists them.
List<Override> _datasetOverrides() => [
      sessionlessPhotometryExportProvider.overrideWith(
        (ref) => Future.value([
          PhotometryMeasurementRow(
            id: 1,
            sessionId: 5,
            capturedImageId: 9,
            objectId: 'V-TEST',
            role: 'target',
            x: 10,
            y: 20,
            flux: 1234,
            differentialMagnitude: -0.31,
            snr: 42,
            uncertainty: 0.02,
            isOutlier: false,
            timestamp: _stamp,
          ),
        ]),
      ),
      sessionlessFrameQualityMetricsExportProvider.overrideWith(
        (ref) => Future.value([
          ScienceFrameQualityMetricsRow(
            id: 1,
            sessionId: 5,
            capturedImageId: 9,
            timestamp: _stamp,
            median: 100,
            mean: 101,
            stdDev: 12,
            mad: 8,
            background: 90,
            noise: 3,
            snr: 30,
            dynamicRangeP1P99: 4000,
            lowClipPercent: 0.1,
            highClipPercent: 0.2,
            uniformityCv: 0.03,
            gradientX: 0.01,
            gradientY: 0.02,
            processingTier: 'full',
            processingMs: 42,
          ),
        ]),
      ),
      sessionlessTransparencySamplesExportProvider.overrideWith(
        (ref) => Future.value([
          TransparencySampleRow(
            id: 1,
            sessionId: 5,
            capturedImageId: 9,
            transparencyPercent: 82.5,
            extinctionCoefficient: 0.21,
            qualityBucket: 'good',
            confidence: 0.9,
            timestamp: _stamp,
          ),
        ]),
      ),
      sessionlessPsfTilesExportProvider.overrideWith(
        (ref) => Future.value([
          PsfFieldTileRow(
            id: 1,
            sessionId: 5,
            capturedImageId: 9,
            tileRow: 2,
            tileCol: 3,
            starCount: 40,
            medianFwhm: 2.5,
            medianHfr: 1.8,
            medianEccentricity: 0.12,
            roundness: 0.95,
            timestamp: _stamp,
          ),
        ]),
      ),
      sessionlessResidualVectorsExportProvider.overrideWith(
        (ref) => Future.value([
          AstrometryResidualVectorRow(
            id: 1,
            sessionId: 5,
            capturedImageId: 9,
            x: 11,
            y: 22,
            dxArcsec: 0.4,
            dyArcsec: -0.3,
            magnitudeArcsec: 0.5,
            recommendationCode: 'tilt',
            timestamp: _stamp,
          ),
        ]),
      ),
      sessionlessCalibrationsExportProvider.overrideWith(
        (ref) => Future.value([
          FramePhotometricCalibrationRow(
            id: 1,
            sessionId: 5,
            capturedImageId: 9,
            isCalibrated: true,
            zeroPoint: 21.4,
            limitingMag3Sigma: 19.2,
            limitingMag5Sigma: 18.6,
            matchedStarCount: 55,
            calibrationRms: 0.04,
            catalogSource: 'gaia',
            solverId: 'astap',
            timestamp: _stamp,
          ),
        ]),
      ),
      sessionlessMovingObjectCandidatesExportProvider.overrideWith(
        (ref) => Future.value([
          MovingObjectCandidateRow(
            id: 1,
            sessionId: 5,
            capturedImageId: 9,
            candidateId: 'CAND-1',
            raDegrees: 250.42,
            decDegrees: 36.46,
            motionArcsecPerMinute: 1.85,
            positionAngleDegrees: 112.0,
            confidence: 0.82,
            isKnownObject: false,
            objectName: null,
            source: 'difference-image',
            timestamp: _stamp,
          ),
        ]),
      ),
    ];

/// Header row, then the one seeded data row, for each dataset in hub order.
const _expected = <String>[
  'Session ID,Image ID,Object ID,Role,X,Y,Flux,Differential Magnitude,SNR,'
      'Uncertainty,Is Outlier,Timestamp (UTC),JD\r\n'
      '5,9,V-TEST,target,10.0,20.0,1234.0,-0.31,42.0,0.02,false,'
      '2026-08-01T09:00:00.000Z,2461253.875',
  'Session ID,Image ID,Timestamp (UTC),Median,Mean,StdDev,MAD,Background,'
      'Noise,SNR,Dynamic Range (P1-P99),Low Clip %,High Clip %,Uniformity CV,'
      'Gradient X,Gradient Y,Processing Tier,Processing Ms\r\n'
      '5,9,2026-08-01T09:00:00.000Z,100.0,101.0,12.0,8.0,90.0,3.0,30.0,4000.0,'
      '0.1,0.2,0.03,0.01,0.02,full,42',
  'Session ID,Image ID,Transparency %,Extinction Coefficient,Quality Bucket,'
      'Confidence,Timestamp (UTC)\r\n'
      '5,9,82.5,0.21,good,0.9,2026-08-01T09:00:00.000Z',
  'Session ID,Image ID,Tile Row,Tile Col,Star Count,Median FWHM,Median HFR,'
      'Median Eccentricity,Roundness,Timestamp (UTC)\r\n'
      '5,9,2,3,40,2.5,1.8,0.12,0.95,2026-08-01T09:00:00.000Z',
  'Session ID,Image ID,X,Y,dX (arcsec),dY (arcsec),Magnitude (arcsec),'
      'Recommendation,Timestamp (UTC)\r\n'
      '5,9,11.0,22.0,0.4,-0.3,0.5,tilt,2026-08-01T09:00:00.000Z',
  'Session ID,Image ID,Is Calibrated,Zero Point,Lim Mag 3-sigma,'
      'Lim Mag 5-sigma,Matched Stars,Calibration RMS,Catalog Source,Solver ID,'
      'Timestamp (UTC)\r\n'
      '5,9,true,21.4,19.2,18.6,55,0.04,gaia,astap,2026-08-01T09:00:00.000Z',
  'Session ID,Image ID,Candidate ID,RA (deg),Dec (deg),Motion (arcsec/min),'
      'Position Angle (deg),Confidence,Is Known Object,Object Name,Source,'
      'Timestamp (UTC)\r\n'
      '5,9,CAND-1,250.42,36.46,1.85,112.0,0.82,false,,difference-image,'
      '2026-08-01T09:00:00.000Z',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('science-export-parity');
    _view.physicalSize = const Size(1200, 2600);
    _view.devicePixelRatio = 1;
  });

  tearDown(() {
    _view.resetPhysicalSize();
    _view.resetDevicePixelRatio();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  for (var index = 0; index < _expected.length; index++) {
    testWidgets('CSV #$index keeps its exact header and column order',
        (tester) async {
      String? csv;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            allSessionsProvider.overrideWith(
              (ref) => Stream.value(const <ImagingSession>[]),
            ),
            allTransientDetectionsProvider.overrideWith(
              (ref) => Stream.value(const <TransientDetectionRow>[]),
            ),
            ..._datasetOverrides(),
            scienceExportDirectoryProvider.overrideWith((ref) {
              return Directory('${tempDir.path}/exports')
                ..createSync(recursive: true);
            }),
            scienceExportSavePickerProvider.overrideWithValue(
              ({
                required fileName,
                required initialDirectory,
                required allowedExtensions,
              }) async =>
                  '$initialDirectory/$fileName',
            ),
            scienceExportFileWriterProvider.overrideWithValue((file, contents) {
              csv = contents;
              return Future<void>.value();
            }),
          ],
          child: const MaterialApp(home: Scaffold(body: ScienceExportHub())),
        ),
      );
      await tester.pumpAndSettle();

      // The seven CSV buttons render in dataset order.
      final button = find.widgetWithText(SkotiqButton, 'CSV').at(index);
      await tester.ensureVisible(button);
      await tester.tap(button);
      for (var attempt = 0; attempt < 100 && csv == null; attempt++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pumpAndSettle();

      expect(csv, isNotNull);
      expect(csv!.trimRight(), _expected[index]);
    });
  }
}
