// Widget tests for ZeroPointTrendCard and SolveRateTrendCard.
//
// These tests focus on the *informational* layer: empty-state messaging,
// rendering with a single data point (which should still show the latest
// value pill but skip the chart), and end-to-end rendering with a multi-
// frame trend.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_trend_cards.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as drift
    show CapturedImage;
import 'package:skotiq_ui/skotiq_ui.dart';

const _baseTs = '2025-01-01T20:00:00.000Z';

drift.CapturedImage _img({
  required int id,
  required Duration offset,
  required bool solved,
}) {
  final ts = DateTime.parse(_baseTs).add(offset);
  return drift.CapturedImage(
    id: id,
    filePath: '/tmp/$id.fits',
    fileName: '$id.fits',
    fileFormat: 'fits',
    frameType: 'light',
    exposureDuration: 60.0,
    binX: 1,
    binY: 1,
    isPlateSolved: solved,
    capturedAt: ts,
    createdAt: ts,
    isAccepted: true,
  );
}

FramePhotometricCalibrationRow _calRow({
  required int id,
  required Duration offset,
  required double zp,
  bool isCalibrated = true,
}) {
  return FramePhotometricCalibrationRow(
    id: id,
    capturedImageId: id,
    sessionId: 1,
    isCalibrated: isCalibrated,
    zeroPoint: zp,
    limitingMag3Sigma: null,
    limitingMag5Sigma: null,
    matchedStarCount: 24,
    calibrationRms: 0.03,
    catalogSource: 'localGaia',
    solverId: 'astrometry.net',
    timestamp: DateTime.parse(_baseTs).add(offset),
  );
}

void main() {
  final theme = ThemeData.dark().copyWith(
    extensions: const <ThemeExtension<dynamic>>[SkotiqColors.dark],
  );
  const colors = SkotiqColors.dark;

  Future<void> pumpZpCard(
    WidgetTester tester,
    List<FramePhotometricCalibrationRow> rows,
  ) async {
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Scaffold(
        body: ZeroPointTrendCard(
          colors: colors,
          calibrations: rows,
        ),
      ),
    ));
  }

  Future<void> pumpSolveCard(
    WidgetTester tester,
    List<drift.CapturedImage> frames,
  ) async {
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Scaffold(
        body: SolveRateTrendCard(
          colors: colors,
          lightFrames: frames,
        ),
      ),
    ));
  }

  testWidgets('ZeroPointTrendCard renders empty-state copy with no data',
      (tester) async {
    await pumpZpCard(tester, const []);
    expect(find.text('Zero point over time'), findsOneWidget);
    expect(
      find.textContaining('appears once at least one frame'),
      findsOneWidget,
    );
  });

  testWidgets('ZeroPointTrendCard with multiple frames shows pill + chart',
      (tester) async {
    final rows = <FramePhotometricCalibrationRow>[
      _calRow(id: 1, offset: const Duration(minutes: 0), zp: 24.10),
      _calRow(id: 2, offset: const Duration(minutes: 5), zp: 24.18),
      _calRow(id: 3, offset: const Duration(minutes: 11), zp: 24.32),
    ];
    await pumpZpCard(tester, rows);
    expect(find.text('Zero point over time'), findsOneWidget);
    expect(find.text('24.32'), findsOneWidget,
        reason: 'latest ZP is shown in the pill.');
    expect(find.textContaining('appears once'), findsNothing,
        reason: 'empty placeholder must not be drawn when data exists.');
  });

  testWidgets('ZeroPointTrendCard drops uncalibrated frames', (tester) async {
    final rows = <FramePhotometricCalibrationRow>[
      _calRow(id: 1, offset: const Duration(minutes: 0), zp: 24.10),
      _calRow(
          id: 2,
          offset: const Duration(minutes: 5),
          zp: 0.0,
          isCalibrated: false),
    ];
    await pumpZpCard(tester, rows);
    // Only one calibrated frame; the chart needs >= 2 points so it stays
    // in placeholder mode but the latest pill still shows the calibrated
    // value, not the uncalibrated zero.
    expect(find.text('24.10'), findsOneWidget);
    expect(find.text('0.00'), findsNothing);
  });

  testWidgets('SolveRateTrendCard with two solved frames reads 100%',
      (tester) async {
    final frames = <drift.CapturedImage>[
      _img(id: 1, offset: const Duration(minutes: 0), solved: true),
      _img(id: 2, offset: const Duration(minutes: 4), solved: true),
    ];
    await pumpSolveCard(tester, frames);
    expect(find.text('Plate-solve rate (rolling)'), findsOneWidget);
    expect(find.text('100%'), findsAtLeastNWidgets(1));
  });

  testWidgets('SolveRateTrendCard with mixed history shows latest window',
      (tester) async {
    final frames = <drift.CapturedImage>[
      for (var i = 0; i < 6; i++)
        _img(id: i + 1, offset: Duration(minutes: i * 3), solved: true),
      // Last two frames fail to solve — rolling window over 8 last frames
      // becomes 6/8 = 75%.
      _img(id: 7, offset: const Duration(minutes: 21), solved: false),
      _img(id: 8, offset: const Duration(minutes: 25), solved: false),
    ];
    await pumpSolveCard(tester, frames);
    expect(find.text('75%'), findsAtLeastNWidgets(1));
  });
}
