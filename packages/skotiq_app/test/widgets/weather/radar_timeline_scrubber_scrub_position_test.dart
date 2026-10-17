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

/// The scrub track: the only CustomPaint in the scrubber with a fixed height.
final _track = find.byWidgetPredicate(
  (widget) => widget is CustomPaint && widget.size.height == 40,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The frame you land on has to be the frame under your finger. Measuring the
  // scrub off the whole control row and correcting with a fixed allowance for
  // the transport buttons carries both an offset and a scale error that grow
  // with the surface width.
  for (final surface in const [Size(1000, 500), Size(2560, 700)]) {
    testWidgets('scrubbing lands on the frame under the pointer at $surface',
        (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = surface;
      addTearDown(() {
        tester.view.resetDevicePixelRatio();
        tester.view.resetPhysicalSize();
      });

      final frames = [for (var i = 0; i < 100; i++) _frame(i)];
      final reported = <int>[];

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: Scaffold(
              body: RadarTimelineScrubber(
                frames: frames,
                currentIndex: 0,
                onFrameChanged: reported.add,
                isPlaying: false,
                onPlayPauseToggle: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final rect = tester.getRect(_track);
      for (final fraction in const [0.25, 0.5, 0.75]) {
        reported.clear();
        final target = Offset(
          rect.left + rect.width * fraction,
          rect.center.dy,
        );
        final gesture = await tester.startGesture(
          Offset(rect.left + 4, rect.center.dy),
        );
        await tester.pump();
        // Two moves: the first is consumed settling the drag past touch slop,
        // the second reports the pointer exactly on `target`.
        await gesture.moveTo(target + const Offset(40, 0));
        await tester.pump();
        await gesture.moveTo(target);
        await tester.pump();
        await gesture.up();
        await tester.pump();

        expect(
          reported.last,
          (fraction * frames.length).floor(),
          reason: 'scrub to ${fraction * 100}% of the track',
        );
      }
    });
  }
}
