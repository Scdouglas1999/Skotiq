import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';

void main() {
  group('LabelLayoutManager occupancy sharing', () {
    test('seed transfers another layer\'s placements', () {
      const canvasSize = Size(800, 600);
      const labelSize = Size(48, 16);

      // The base layer places a label.
      final base = LabelLayoutManager();
      final basePos = base.findPlacement(
        const Offset(100, 100),
        labelSize,
        canvasSize,
      );
      expect(basePos, isNotNull);
      expect(base.occupancy, hasLength(1));

      // Without seeding, a second layer happily reuses the same spot — this is
      // exactly the bug: star names drawn straight through DSO/planet labels.
      final unseeded = LabelLayoutManager();
      expect(
        unseeded.findPlacement(const Offset(100, 100), labelSize, canvasSize),
        equals(const Offset(100, 100)),
      );

      // Seeded with the base layer's occupancy, the overlay must move.
      final overlay = LabelLayoutManager()..seed(base.occupancy);
      final overlayPos = overlay.findPlacement(
        const Offset(100, 100),
        labelSize,
        canvasSize,
      );
      expect(overlayPos, isNotNull);
      expect(overlayPos, isNot(equals(basePos)));
      expect(
        Rect.fromLTWH(
          overlayPos!.dx,
          overlayPos.dy,
          labelSize.width,
          labelSize.height,
        ).overlaps(
          Rect.fromLTWH(
            basePos!.dx,
            basePos.dy,
            labelSize.width,
            labelSize.height,
          ),
        ),
        isFalse,
      );
    });

    test('occupancy is a snapshot, not a live view', () {
      final manager = LabelLayoutManager();
      manager.findPlacement(
        const Offset(10, 10),
        const Size(40, 12),
        const Size(400, 300),
      );
      final snapshot = manager.occupancy;
      manager.findPlacement(
        const Offset(200, 200),
        const Size(40, 12),
        const Size(400, 300),
      );
      expect(snapshot, hasLength(1));
    });
  });

  group('LabelLayoutManager edge handling', () {
    test(
      'a label overhanging an edge is nudged inside rather than dropped',
      () {
        final manager = LabelLayoutManager();
        const canvasSize = Size(400, 300);
        const labelSize = Size(60, 20);

        // Preferred position would put the box past the right/bottom edges.
        final pos = manager.findPlacement(
          const Offset(380, 290),
          labelSize,
          canvasSize,
        );

        expect(pos, isNotNull, reason: 'edge labels must not be dropped');
        final rect = Rect.fromLTWH(
          pos!.dx,
          pos.dy,
          labelSize.width,
          labelSize.height,
        );
        expect(rect.left >= 0, isTrue);
        expect(rect.top >= 0, isTrue);
        expect(rect.right <= canvasSize.width, isTrue);
        expect(rect.bottom <= canvasSize.height, isTrue);
      },
    );

    test('a label larger than the canvas is refused', () {
      final manager = LabelLayoutManager();
      expect(
        manager.findPlacement(
          Offset.zero,
          const Size(500, 20),
          const Size(400, 300),
        ),
        isNull,
      );
    });

    test('a label anchored entirely off-screen is refused, not clamped in', () {
      final manager = LabelLayoutManager();
      const canvasSize = Size(400, 300);
      const labelSize = Size(60, 20);

      // Anchors far outside the canvas belong to objects that are not in view;
      // clamping them to the edge would advertise off-screen objects.
      expect(
        manager.findPlacement(const Offset(-4000, 150), labelSize, canvasSize),
        isNull,
      );
      expect(
        manager.findPlacement(const Offset(150, 9000), labelSize, canvasSize),
        isNull,
      );
    });
  });
}
