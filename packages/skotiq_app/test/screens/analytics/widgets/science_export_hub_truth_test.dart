// Two claims the Science Data Export hub made that were not true.
//
// 1. Opened from the Science header (`const ScienceExportHub()`), the MPC row
//    read "No moving object candidates available to report yet." and its Open
//    button did nothing — while the page behind the dialog listed two
//    candidates. The list was a constructor argument that two of the three call
//    sites never passed.
// 2. Every CSV wrote `toIso8601String()` on a LOCAL DateTime, so a measurement
//    stored at 09:00 UTC exported as "2026-08-01T05:00:00.000" on a UTC-4 host
//    with no offset and no Z.

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

ImagingSession _session() => ImagingSession(
      id: 5,
      name: 'Night E - M13',
      startTime: DateTime.utc(2026, 7, 31, 23),
      totalExposures: 2,
      successfulExposures: 2,
      failedExposures: 0,
      totalIntegrationSecs: 600,
      autofocusCount: 0,
      status: 'completed',
    );

MovingObjectCandidateRow _candidate(int id) => MovingObjectCandidateRow(
      id: id,
      sessionId: 5,
      candidateId: 'CAND-$id',
      raDegrees: 250.42,
      decDegrees: 36.46,
      motionArcsecPerMinute: 1.85,
      positionAngleDegrees: 112.0,
      confidence: 0.82,
      isKnownObject: false,
      source: 'difference-image',
      timestamp: DateTime.utc(2026, 8, 1, 9),
    );

/// 09:00 UTC, carried as the LOCAL-flagged DateTime drift hands back for a
/// unix-seconds column — the row whose CSV stamp read 05:00 with no zone.
final _instant = DateTime.utc(2026, 8, 1, 9);
final _measurement = PhotometryMeasurementRow(
  id: 1,
  objectId: 'V-TEST',
  role: 'target',
  x: 10,
  y: 20,
  flux: 1234,
  differentialMagnitude: -0.31,
  snr: 42,
  uncertainty: 0.02,
  isOutlier: false,
  timestamp:
      DateTime.fromMillisecondsSinceEpoch(_instant.millisecondsSinceEpoch),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('science-export-truth');
    _view.physicalSize = const Size(1200, 1400);
    _view.devicePixelRatio = 1;
  });

  tearDown(() {
    _view.resetPhysicalSize();
    _view.resetDevicePixelRatio();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('the MPC row finds the candidates the page behind it lists',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          allSessionsProvider.overrideWith((ref) => Stream.value([_session()])),
          allTransientDetectionsProvider.overrideWith(
            (ref) => Stream.value(const <TransientDetectionRow>[]),
          ),
          sessionMovingObjectCandidatesProvider.overrideWith(
            (ref, id) => Stream.value([_candidate(1), _candidate(2)]),
          ),
        ],
        child: const MaterialApp(
          // No mpcCandidates argument — the Science header's entry point.
          home: Scaffold(body: ScienceExportHub()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('No moving object candidates available to report yet.'),
      findsNothing,
      reason: 'the analysed session has two candidates',
    );
    final open = find.widgetWithText(SkotiqButton, 'Open').first;
    expect(
      tester.widget<SkotiqButton>(open).onPressed,
      isNotNull,
      reason: 'the Open button was inert',
    );
  });

  testWidgets('photometry CSV timestamps are UTC and carry a JD column',
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
          sessionlessPhotometryExportProvider
              .overrideWith((ref) => Future.value([_measurement])),
          scienceExportDirectoryProvider.overrideWith((ref) {
            final directory = Directory('${tempDir.path}/exports')
              ..createSync(recursive: true);
            return directory;
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

    final photometryButton = find.widgetWithText(SkotiqButton, 'CSV').first;
    await tester.ensureVisible(photometryButton);
    await tester.tap(photometryButton);
    for (var attempt = 0; attempt < 100 && csv == null; attempt++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pumpAndSettle();

    expect(csv, isNotNull);
    expect(csv, contains('Timestamp (UTC)'));
    expect(
      csv,
      contains('2026-08-01T09:00:00.000Z'),
      reason: 'the row was recorded at 09:00 UTC; local wall clock is a lie '
          'that changes with the observer and with DST',
    );
    // JD 2461253.875 == 2026-08-01T09:00Z.
    expect(csv, contains('JD'));
    expect(csv, contains('2461253.875'));
  });
}
