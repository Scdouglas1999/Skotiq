import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/weather/radar_timeline_scrubber.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

RadarFrame _frame(int minute) => RadarFrame(
      timestamp: DateTime.utc(2026, 7, 15, 2, minute),
      tileUrlTemplate: 'https://example.invalid/$minute/{z}/{x}/{y}.png',
      north: 36,
      south: 34,
      east: -117,
      west: -119,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a shrinking radar refresh clamps and reports the frame index',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 500);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    final frames = ValueNotifier<List<RadarFrame>>([
      _frame(0),
      _frame(5),
      _frame(10),
    ]);
    addTearDown(frames.dispose);
    var currentIndex = 2;
    final corrected = <int>[];

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: ValueListenableBuilder<List<RadarFrame>>(
              valueListenable: frames,
              builder: (context, value, child) => RadarTimelineScrubber(
                frames: value,
                currentIndex: currentIndex,
                onFrameChanged: (index) {
                  corrected.add(index);
                  currentIndex = index;
                },
                isPlaying: false,
                onPlayPauseToggle: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Frame 3 of 3'), findsOneWidget);

    frames.value = [_frame(0), _frame(5)];
    await tester.pump();
    await tester.pump();

    expect(find.text('Frame 2 of 2'), findsOneWidget);
    expect(corrected, [1]);
    expect(tester.takeException(), isNull);
  });
}
