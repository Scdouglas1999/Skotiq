import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_hud.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets(
      'HUD clears persisted stats without an image and follows the displayed frame',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(lastImageStatsProvider.notifier).state =
        const ImageStats(hfr: 9, eccentricity: 0.99);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: FrameStatsHud(eccentricity: 0.11))),
    ));
    expect(find.text('—'), findsNWidgets(5));
    expect(find.text('0.11'), findsNothing);
    container.read(currentImageProvider.notifier).state = CapturedImageData(
      width: 1,
      height: 1,
      displayData: Uint8List(4),
      histogram: const [],
      stats: const ImageStats(
          hfr: 2, eccentricity: 0.25, starCount: 12, mean: 100, median: 90),
      capturedAt: DateTime(2026),
      settings: const ExposureSettings(exposureTime: 1, gain: 0, offset: 0),
    );
    await tester.pump();
    expect(find.textContaining('2.00', findRichText: true), findsOneWidget);
    expect(find.text('0.25'), findsOneWidget);
    expect(find.text('9.00'), findsNothing);
    expect(find.text('0.99'), findsNothing);
  });
}
