import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/preview_transform.dart';

void main() {
  test('computeImageOffset centers image with zoom and pan', () {
    final offset = computeImageOffset(
      viewportSize: const Size(200, 100),
      imageSize: const Size(50, 50),
      zoomLevel: 2.0,
      panOffset: const Offset(10, -5),
    );

    expect(offset, const Offset(60, -5));
  });

  test('imageToViewport and viewportToImage invert correctly', () {
    const imageOffset = Offset(25, 10);
    const zoomLevel = 1.5;
    const imagePoint = Offset(40, 20);

    final viewportPoint = imageToViewport(
      imagePoint: imagePoint,
      imageOffset: imageOffset,
      zoomLevel: zoomLevel,
    );

    final roundTrip = viewportToImage(
      viewportPoint: viewportPoint,
      imageOffset: imageOffset,
      zoomLevel: zoomLevel,
    );

    expect(roundTrip.dx, closeTo(imagePoint.dx, 0.0001));
    expect(roundTrip.dy, closeTo(imagePoint.dy, 0.0001));
  });
}
