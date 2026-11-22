// The imaging screen's quality badge shows the run's verdict on the frame on
// screen: the one the frame strip, the frame pill and Tonight's Last frame
// show.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/sub_quality_badge.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_frames_provider.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _kept = '/captures/IC405/IC405_Ha_0001.fits';
const _rejected = '/captures/IC405/Reject/IC405_Ha_0002.fits';
const _reason = 'HFR 4.12 px exceeds baseline 2.70 px + 50% (limit 4.05 px)';

DbCapturedImage _row(int id, String path, {required bool kept}) =>
    DbCapturedImage(
      id: id,
      filePath: path,
      fileName: path.split('/').last,
      fileFormat: 'fits',
      frameType: 'light',
      filter: 'Ha',
      exposureDuration: 180,
      binX: 1,
      binY: 1,
      capturedAt: DateTime(2026, 11, 16, 21, id),
      createdAt: DateTime(2026, 11, 16, 21, id),
      isAccepted: kept,
      rejectionReason: kept ? null : _reason,
      hfr: kept ? 3.61 : 4.12,
      starCount: 900,
      isPlateSolved: false,
    );

Future<void> _pump(
  WidgetTester tester, {
  required ImageStats? stats,
  String? filePath,
  double? eccentricity,
  Widget child = const SubQualityBadge(),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 600);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final image = filePath == null || stats == null
      ? null
      : CapturedImageData(
          width: 1,
          height: 1,
          displayData: Uint8List(4),
          histogram: const [],
          capturedAt: DateTime(2026, 11, 16, 21),
          settings: const ExposureSettings(
            exposureTime: 180,
            gain: 139,
            offset: 21,
            filter: 'Ha',
          ),
          filePath: filePath,
          stats: stats,
        );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        lastImageStatsProvider.overrideWith((ref) => stats),
        currentImageProvider.overrideWith((ref) => image),
        nightSessionLightRowsProvider.overrideWithValue([
          _row(1, _kept, kept: true),
          _row(2, _rejected, kept: false),
        ]),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Center(
            child: child is SubQualityBadge
                ? SubQualityBadge(eccentricity: eccentricity)
                : child,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders nothing when there is no captured frame', (
    tester,
  ) async {
    await _pump(tester, stats: null);

    expect(find.textContaining('HFR'), findsNothing);
    expect(find.text('ACCEPT'), findsNothing);
    expect(find.text('REJECT'), findsNothing);
    expect(tester.getSize(find.byType(SubQualityBadge)), Size.zero);
  });

  testWidgets('a frame the run kept is ACCEPT, whatever its HFR', (
    tester,
  ) async {
    await _pump(
      tester,
      stats: const ImageStats(hfr: 3.61, starCount: 900),
      filePath: _kept,
    );

    expect(find.text('ACCEPT'), findsOneWidget);
    expect(find.text('REJECT'), findsNothing);
    expect(find.text('3.61'), findsOneWidget);
    expect(find.text('900'), findsOneWidget);
  });

  testWidgets('a frame the run rejected is REJECT with the run\'s reason', (
    tester,
  ) async {
    await _pump(
      tester,
      stats: const ImageStats(hfr: 4.12, starCount: 900),
      filePath: _rejected,
    );

    expect(find.text('REJECT'), findsOneWidget);
    final tooltip = tester.widget<SkotiqTooltip>(find.byType(SkotiqTooltip));
    expect(tooltip.message, _reason);
  });

  testWidgets('a frame no run graded has no verdict', (tester) async {
    await _pump(
      tester,
      stats: const ImageStats(hfr: 9.0, starCount: 3),
      filePath: '/captures/snapshot.fits',
    );

    expect(find.text('ACCEPT'), findsNothing);
    expect(find.text('REJECT'), findsNothing);
    expect(find.text('9.00'), findsOneWidget);
  });

  testWidgets('the verdict alone, for the frame pill', (tester) async {
    await _pump(
      tester,
      stats: const ImageStats(hfr: 4.12, starCount: 900),
      filePath: _rejected,
      child: const SubQualityVerdict(),
    );

    expect(find.text('REJECT'), findsOneWidget);
    expect(find.text('4.12'), findsNothing);
  });

  testWidgets('null eccentricity renders ECC dash', (tester) async {
    await _pump(
      tester,
      stats: const ImageStats(hfr: 2.10, starCount: 180),
    );

    expect(find.text('ECC'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('provided eccentricity renders formatted value', (tester) async {
    await _pump(
      tester,
      stats: const ImageStats(hfr: 2.10, starCount: 180),
      eccentricity: 0.42,
    );

    expect(find.text('0.42'), findsOneWidget);
    expect(find.text('—'), findsNothing);
  });
}
