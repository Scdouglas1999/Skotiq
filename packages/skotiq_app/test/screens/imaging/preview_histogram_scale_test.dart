import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_hud.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('histogram axis follows completed counts, not raw pixel arrival',
      (tester) async {
    final counts = StateProvider<({List<int> bins, bool isRaw})?>((ref) => (
          bins: List<int>.filled(256, 1),
          isRaw: false,
        ));
    final container = ProviderContainer(overrides: [
      previewDisplayHistogramProvider.overrideWith((ref) => ref.watch(counts)),
    ]);
    addTearDown(container.dispose);
    container.read(currentImageProvider.notifier).state = CapturedImageData(
      width: 2,
      height: 1,
      displayData: Uint8List(8),
      histogram: List<int>.filled(256, 1),
      stats: const ImageStats(),
      capturedAt: DateTime.utc(2026, 11, 14),
      settings: const ExposureSettings(exposureTime: 2, gain: 0, offset: 0),
      rawU16: Uint16List.fromList([0, 65535]),
      rawLoadStatus: RawLoadStatus.ready,
    );
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: HistogramHud()),
      ),
    ));

    expect(find.text('black'), findsOneWidget);
    expect(find.text('white'), findsOneWidget);
    expect(find.text('65535'), findsNothing);

    container.read(counts.notifier).state = (
      bins: List<int>.filled(256, 2),
      isRaw: true,
    );
    await tester.pump();
    expect(find.text('0'), findsOneWidget);
    expect(find.text('65535'), findsOneWidget);
    expect(find.text('black'), findsNothing);

    container.read(counts.notifier).state = (
      bins: List<int>.filled(256, 3),
      isRaw: false,
    );
    await tester.pump();
    expect(find.text('black'), findsOneWidget);
    expect(find.text('65535'), findsNothing,
        reason: 'a new frame has its own pending raw histogram');
  });
}
