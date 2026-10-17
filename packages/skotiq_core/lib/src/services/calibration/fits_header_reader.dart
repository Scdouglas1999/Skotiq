import 'dart:io';

/// Minimal FITS *primary-HDU header* reader used by the Calibration Library
/// for metadata enrichment (camera / gain / temperature / filter / exposure
/// of master files whose DB rows lack those columns).
///
/// Deliberately tiny: it reads 2880-byte header blocks until the `END` card,
/// never touches pixel data (so a multi-hundred-MB master costs a few KB of
/// I/O), and only the primary HDU is consulted — master calibration frames
/// written by Skotiq, NINA, SiriL, and PixInsight all keep their capture
/// keywords there. The full pixel parser lives in `DarkLibraryService`; the
/// header *writer* in `science/fits_header_writer.dart`.
class FitsHeaderReader {
  const FitsHeaderReader();

  /// FITS header block size (bytes) and card size (bytes) per the standard.
  static const int blockSize = 2880;
  static const int cardSize = 80;

  /// Safety cap: stop after this many header blocks even without an `END`
  /// card (36 blocks = ~100 KB ≈ 1296 cards, far beyond any sane header).
  static const int maxBlocks = 36;

  /// Read the primary-HDU header cards of [path] into a keyword → raw value
  /// map (values still carry FITS quoting; use the typed helpers below).
  ///
  /// Throws [FormatException] when the file is not a FITS file (no `SIMPLE`
  /// first card) or the header has no `END` card within [maxBlocks] blocks;
  /// I/O errors propagate as-is. Callers doing best-effort enrichment catch
  /// and continue.
  Future<Map<String, String>> readPrimaryHeader(String path) async {
    final raf = await File(path).open();
    try {
      final headers = <String, String>{};
      var sawSimple = false;
      for (var block = 0; block < maxBlocks; block++) {
        final bytes = await raf.read(blockSize);
        if (bytes.length < blockSize) {
          throw FormatException(
            'Truncated FITS header in $path: '
            '${bytes.length} bytes in block $block',
          );
        }
        for (var off = 0; off < blockSize; off += cardSize) {
          final card = String.fromCharCodes(bytes, off, off + cardSize);
          final keyword = card.substring(0, 8).trim();
          if (block == 0 && off == 0) {
            if (keyword != 'SIMPLE') {
              throw FormatException(
                'Not a FITS file (first card is "$keyword", expected '
                'SIMPLE): $path',
              );
            }
            sawSimple = true;
          }
          if (keyword == 'END') return headers;
          if (keyword.isEmpty || keyword == 'COMMENT' || keyword == 'HISTORY') {
            continue;
          }
          // Value cards have "= " in columns 9-10 per the FITS standard.
          if (card.length < 10 || card[8] != '=') continue;
          headers[keyword] = _rawValue(card);
        }
      }
      throw FormatException(
        sawSimple
            ? 'FITS header of $path has no END card within $maxBlocks blocks'
            : 'Not a FITS file: $path',
      );
    } finally {
      await raf.close();
    }
  }

  /// String value of [key]: strips the FITS single-quote convention
  /// (`'ASI2600MC '` → `ASI2600MC`, with `''` un-escaped to `'`).
  static String? stringValue(Map<String, String> headers, String key) {
    final raw = headers[key]?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (raw.startsWith("'")) {
      final close = raw.lastIndexOf("'");
      if (close > 0) {
        final inner = raw.substring(1, close).replaceAll("''", "'").trim();
        return inner.isEmpty ? null : inner;
      }
    }
    return raw;
  }

  /// Numeric value of [key], tolerating integer literals (`GAIN = 100`) and
  /// scientific notation (`EXPTIME = 3.0E2`).
  static double? doubleValue(Map<String, String> headers, String key) {
    final raw = headers[key]?.trim();
    if (raw == null || raw.isEmpty) return null;
    return double.tryParse(raw);
  }

  /// Integer value of [key]; a float-formatted integer (`100.0`) rounds.
  static int? intValue(Map<String, String> headers, String key) {
    final asDouble = doubleValue(headers, key);
    if (asDouble == null || !asDouble.isFinite) return null;
    return asDouble.round();
  }

  /// First present key wins — for keyword aliases like EXPTIME/EXPOSURE.
  static double? firstDouble(Map<String, String> headers, List<String> keys) {
    for (final key in keys) {
      final value = doubleValue(headers, key);
      if (value != null) return value;
    }
    return null;
  }

  /// Strip the inline comment and return the raw value text of a card.
  static String _rawValue(String card) {
    final body = card.substring(10);
    // A '/' starts the comment — but not inside a quoted string value.
    if (body.trimLeft().startsWith("'")) {
      final start = body.indexOf("'");
      var i = start + 1;
      while (i < body.length) {
        if (body[i] == "'") {
          // Escaped quote ('') stays inside the string.
          if (i + 1 < body.length && body[i + 1] == "'") {
            i += 2;
            continue;
          }
          break;
        }
        i++;
      }
      return body.substring(start, i < body.length ? i + 1 : body.length);
    }
    final slash = body.indexOf('/');
    return (slash >= 0 ? body.substring(0, slash) : body).trim();
  }
}
