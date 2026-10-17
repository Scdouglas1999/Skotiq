/// Presentation helpers for the shared `rows × columns` mosaic convention.
library;

/// `3 wide × 2 high` — a mosaic's grid dimensions, axis-labelled so the reader
/// never has to guess the convention.
///
/// Takes named parameters on purpose: a positional `(rows, cols)` pair is
/// exactly the call that transposed the two screens in the first place.
String formatMosaicGrid({required int cols, required int rows}) =>
    '$cols wide × $rows high';
