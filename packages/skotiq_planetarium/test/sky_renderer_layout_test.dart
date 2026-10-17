import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/rendering/sky_renderer.dart';

void main() {
  test('label layout manager places non-overlapping labels in bounds', () {
    final manager = LabelLayoutManager();
    const canvasSize = Size(800, 600);
    const labelSize = Size(48, 16);

    final placements = <Offset?>[
      manager.findPlacement(const Offset(100, 100), labelSize, canvasSize),
      manager.findPlacement(const Offset(170, 100), labelSize, canvasSize),
      manager.findPlacement(const Offset(240, 100), labelSize, canvasSize),
    ];

    expect(placements.whereType<Offset>(), hasLength(3));
    expect(
      manager.canPlace(
        Rect.fromLTWH(
          placements.first!.dx,
          placements.first!.dy,
          labelSize.width,
          labelSize.height,
        ),
      ),
      isFalse,
    );
  });

  test('label layout manager clear removes previous occupancy', () {
    final manager = LabelLayoutManager();
    const canvasSize = Size(200, 120);
    const labelSize = Size(64, 20);

    final first = manager.findPlacement(
      const Offset(20, 20),
      labelSize,
      canvasSize,
    );
    expect(first, isNotNull);

    manager.clear();

    final second = manager.findPlacement(
      const Offset(20, 20),
      labelSize,
      canvasSize,
    );
    expect(second, equals(const Offset(20, 20)));
  });
}
