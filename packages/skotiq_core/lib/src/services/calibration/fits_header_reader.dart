import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimal header reader for FITS (*primary HDU*) and XISF frames, used by the
/// Calibration Library for metadata enrichment (camera / gain / temperature /
/// filter / exposure of master files whose DB rows lack those columns). An
/// XISF frame's FITS keywords carry the same value text as FITS cards, and its
/// geometry gives NAXIS1/NAXIS2, so callers read both formats alike.
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
  /// map (values still carry FITS quoting; use the typed helpers below). A
  /// string continued on CONTINUE cards is one value.
  ///
  /// Throws [FormatException] when the file is not a FITS file (no `SIMPLE`
  /// first card) or the header has no `END` card within [maxBlocks] blocks;
  /// I/O errors propagate as-is. Callers doing best-effort enrichment catch
  /// and continue.
  Future<Map<String, String>> readPrimaryHeader(String path) async {
    final raf = await File(path).open();
    try {
      final signature = await raf.read(16);
      if (signature.length == 16 &&
          String.fromCharCodes(signature, 0, 8) == 'XISF0100') {
        return await _readXisfKeywords(raf, signature, path);
      }
      await raf.setPosition(0);
      final headers = <String, String>{};
      var sawSimple = false;
      // The keyword whose string value ended in `&` on the card just read.
      String? openLongString;
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
          final continued = openLongString;
          openLongString = null;
          if (keyword == 'CONTINUE') {
            if (continued != null) {
              final joined = _continueString(
                headers[continued]!,
                _rawValue(card),
              );
              if (joined != null) {
                headers[continued] = joined;
                if (_quotedBody(joined)!.endsWith('&')) {
                  openLongString = continued;
                }
              }
            }
            continue;
          }
          if (keyword.isEmpty || keyword == 'COMMENT' || keyword == 'HISTORY') {
            continue;
          }
          // Value cards have "= " in columns 9-10 per the FITS standard.
          if (card.length < 10 || card[8] != '=') continue;
          final value = _rawValue(card);
          headers[keyword] = value;
          if (_quotedBody(value)?.endsWith('&') ?? false) {
            openLongString = keyword;
          }
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

  /// The largest XISF header read here; real headers are kilobytes.
  static const int maxXisfHeader = 16 << 20;

  /// The FITSKeyword elements of the first image of a monolithic XISF file,
  /// as name → value text, plus NAXIS1/NAXIS2 from its geometry.
  static Future<Map<String, String>> _readXisfKeywords(
    RandomAccessFile raf,
    Uint8List signature,
    String path,
  ) async {
    final length = ByteData.sublistView(
      signature,
      8,
      12,
    ).getUint32(0, Endian.little);
    if (length > maxXisfHeader) {
      throw FormatException('XISF header of $path is $length bytes long');
    }
    final xml = utf8.decode(await raf.read(length), allowMalformed: true);
    final image = RegExp(r'<Image\b[^>]*>').firstMatch(xml);
    if (image == null) {
      throw FormatException('XISF file $path holds no image');
    }
    final end = xml.indexOf('</Image>', image.end);
    final body = xml.substring(image.end, end < 0 ? xml.length : end);
    final headers = <String, String>{};
    final geometry = _xmlAttribute(image.group(0)!, 'geometry')?.split(':');
    if (geometry != null && geometry.length >= 3) {
      headers['NAXIS1'] = geometry[0].trim();
      headers['NAXIS2'] = geometry[1].trim();
    }
    for (final element in RegExp(r'<FITSKeyword\b[^>]*>').allMatches(body)) {
      final tag = element.group(0)!;
      final name = _xmlAttribute(tag, 'name')?.trim().toUpperCase();
      if (name == null || name.isEmpty) continue;
      if (name == 'COMMENT' || name == 'HISTORY') continue;
      headers[name] = (_xmlAttribute(tag, 'value') ?? '').trim();
    }
    return headers;
  }

  static String? _xmlAttribute(String tag, String name) {
    final match = RegExp(
      '\\b$name\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')',
    ).firstMatch(tag);
    final raw = match?.group(1) ?? match?.group(2);
    return raw == null ? null : _xmlUnescape(raw);
  }

  static String _xmlUnescape(String text) => text
      .replaceAllMapped(
        RegExp(r'&#(x?)([0-9a-fA-F]+);'),
        (m) => String.fromCharCode(
          int.parse(m.group(2)!, radix: m.group(1)!.isEmpty ? 10 : 16),
        ),
      )
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

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

  /// The text between a quoted value's quotes, trailing blanks dropped; null
  /// for a value that is not a quoted string.
  static String? _quotedBody(String raw) {
    if (raw.length < 2 || !raw.startsWith("'") || !raw.endsWith("'")) {
      return null;
    }
    return raw.substring(1, raw.length - 1).trimRight();
  }

  /// A string value continued by one CONTINUE card (FITS 4.0 section
  /// 4.2.1.2): the `&` ending [head] is replaced by [piece]'s text. Null when
  /// [piece] is not a quoted string, which ends the value as it stands.
  static String? _continueString(String head, String piece) {
    final headText = _quotedBody(head)!;
    final pieceText = _quotedBody(piece);
    if (pieceText == null) return null;
    return "'${headText.substring(0, headText.length - 1)}$pieceText'";
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
