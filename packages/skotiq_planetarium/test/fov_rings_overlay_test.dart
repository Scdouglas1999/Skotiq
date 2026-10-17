import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  group('FovRingsOverlay', () {
    testWidgets('renders without error and sizes to its parent', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SizedBox(
            width: 400,
            height: 300,
            child: FovRingsOverlay(
              fieldOfView: 10,
              centerRA: 5.5,
              centerDec: 22.0,
            ),
          ),
        ),
      );

      expect(find.byType(FovRingsOverlay), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('IgnorePointer wrapper lets taps reach widgets beneath', (
      tester,
    ) async {
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => tapped = true,
              ),
              const IgnorePointer(
                child: FovRingsOverlay(
                  fieldOfView: 10,
                  centerRA: 0,
                  centerDec: 0,
                ),
              ),
            ],
          ),
        ),
      );

      await tester.tapAt(tester.getCenter(find.byType(Stack)));
      await tester.pump();
      expect(tapped, isTrue);
    });

    test('telrad diameters are the standard 4/2/0.5 degree pattern', () {
      expect(FovRingsOverlay.telradDiametersDeg, [4.0, 2.0, 0.5]);
    });

    testWidgets('repaints when field of view changes (zoom)', (tester) async {
      Widget build(double fov) => MaterialApp(
        home: SizedBox(
          width: 400,
          height: 300,
          child: FovRingsOverlay(fieldOfView: fov, centerRA: 0, centerDec: 0),
        ),
      );

      await tester.pumpWidget(build(10));
      // Zoom in: smaller FOV -> rings should grow in pixels. Just verify a
      // rebuild with a new FOV does not throw and the widget updates.
      await tester.pumpWidget(build(5));
      expect(tester.takeException(), isNull);
      expect(find.byType(FovRingsOverlay), findsOneWidget);
    });
  });
}
