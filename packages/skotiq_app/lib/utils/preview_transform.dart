import 'dart:ui';

Offset computeImageOffset({
  required Size viewportSize,
  required Size imageSize,
  required double zoomLevel,
  required Offset panOffset,
}) {
  final scaledSize = Size(
    imageSize.width * zoomLevel,
    imageSize.height * zoomLevel,
  );

  return Offset(
    (viewportSize.width - scaledSize.width) / 2 + panOffset.dx,
    (viewportSize.height - scaledSize.height) / 2 + panOffset.dy,
  );
}

Offset imageToViewport({
  required Offset imagePoint,
  required Offset imageOffset,
  required double zoomLevel,
}) {
  return Offset(
    imagePoint.dx * zoomLevel + imageOffset.dx,
    imagePoint.dy * zoomLevel + imageOffset.dy,
  );
}

Offset viewportToImage({
  required Offset viewportPoint,
  required Offset imageOffset,
  required double zoomLevel,
}) {
  return Offset(
    (viewportPoint.dx - imageOffset.dx) / zoomLevel,
    (viewportPoint.dy - imageOffset.dy) / zoomLevel,
  );
}
