class MosaicOverlap {
  /// Horizontal overlap percentage (0-1)
  final double horizontal;

  /// Vertical overlap percentage (0-1)
  final double vertical;

  const MosaicOverlap({this.horizontal = 0.15, this.vertical = 0.15});

  MosaicOverlap copyWith({double? horizontal, double? vertical}) {
    return MosaicOverlap(
      horizontal: horizontal ?? this.horizontal,
      vertical: vertical ?? this.vertical,
    );
  }
}

/// How many panels it takes to cover an area. Panel positions and numbers
/// come from `mosaicPanelCenters`.
abstract final class MosaicPlanner {
  /// Calculate required number of panels to cover an area
  static (int rows, int cols) calculatePanelCount({
    required double totalWidth,
    required double totalHeight,
    required double panelWidth,
    required double panelHeight,
    MosaicOverlap overlap = const MosaicOverlap(),
  }) {
    // Effective step size accounting for overlap
    final stepWidth = panelWidth * (1 - overlap.horizontal);
    final stepHeight = panelHeight * (1 - overlap.vertical);

    final cols = (totalWidth / stepWidth).ceil().clamp(1, 100);
    final rows = (totalHeight / stepHeight).ceil().clamp(1, 100);

    return (rows, cols);
  }
}
