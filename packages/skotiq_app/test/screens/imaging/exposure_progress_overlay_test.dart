import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/overlay_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  // Owner, live night 2026-10-17: while looping, the image box greyed out for
  // every exposure, so no frame of the loop could be seen.
  testWidgets(
      'exposure progress leaves the frame on screen visible and '
      'touchable', (tester) async {
    var tappedFrame = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  onTap: () => tappedFrame = true,
                  child: const ColoredBox(color: Color(0xFF808080)),
                ),
              ),
              Positioned.fill(
                child: ExposureProgressOverlay(
                  progress: const ExposureProgress(
                    percent: 40,
                    elapsed: 12,
                    remaining: 18,
                  ),
                  colors: SkotiqColors.dark,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Exposing...'), findsOneWidget);
    expect(find.text('18.0s remaining'), findsOneWidget);

    // No scrim: nothing in the overlay paints a full-canvas fill.
    final fills = tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(ExposureProgressOverlay),
            matching: find.byType(Container),
          ),
        )
        .where((c) => c.color != null);
    expect(fills, isEmpty);

    // The frame underneath still receives the pointer (pan, zoom, tap).
    await tester.tapAt(tester.getCenter(find.byType(Scaffold)));
    expect(tappedFrame, isTrue);
  });
}
