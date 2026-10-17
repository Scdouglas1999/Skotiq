import 'dart:typed_data';

/// Minimal FITS validation for published calibration masters.
///
/// The hub does not trust the self-reported dimensions a publisher declares in
/// query params: those drive the client matcher's quality gate, so a publisher
/// could otherwise lie (declare a foreign sensor's geometry) to have a junk /
/// poisoned master surface for someone else's camera. So we parse the real bytes
/// and require the declared geometry to equal the FITS image axes.
///
/// Crucially the geometry alone is NOT enough: `NAXIS1`/`NAXIS2` are header text
/// an attacker writes freely, so a header-only file could declare any geometry.
/// We therefore also require the file to carry a full pixel-data section that is
/// structurally consistent with the declared axes + `BITPIX` (`parse`), and a
/// non-degenerate one (`validatePixelSanity`) — a header-only or all-constant
/// buffer cannot calibrate anything and is rejected.
///
/// `NFRAMES` is read as an UNTRUSTED hint only: it too is uploader-written text,
/// equally forgeable to the `frameCount` query param, so it is never treated as
/// authoritative — the hub caps its influence on ranking (see
/// `SharedCalibrationService.query`).
///
/// It reads the 2880-byte header blocks until the `END` card, parses only the
/// keywords the gate needs, then bounds-checks (and, on demand, statistically
/// samples) the pixel data section.
class FitsMasterHeader {
  const FitsMasterHeader({
    required this.naxis1,
    required this.naxis2,
    required this.naxis3,
    required this.bitpix,
    required this.frameCount,
    required this.dataOffset,
  });

  /// Image width (FITS `NAXIS1`), in pixels.
  final int naxis1;

  /// Image height (FITS `NAXIS2`), in pixels.
  final int naxis2;

  /// Plane count (FITS `NAXIS3`) for a stacked cube, or 1 for a plain 2-D image.
  final int naxis3;

  /// Pixel data type (FITS `BITPIX`): 8/16/32/64 for integers, -32/-64 for IEEE
  /// floats. `|BITPIX| / 8` is the bytes-per-pixel used to size the data section.
  final int bitpix;

  /// Untrusted combined frame-count hint from the `NFRAMES` keyword, or null when
  /// the master records none. Forgeable header text — never treated as
  /// authoritative; the hub caps how much it can influence ranking.
  final int? frameCount;

  /// Byte offset at which the pixel-data section begins (the header length,
  /// rounded up to the 2880-byte block boundary).
  final int dataOffset;

  static const int _blockSize = 2880;
  static const int _cardSize = 80;

  /// Safety cap: 36 blocks (~1296 cards) is far beyond any sane header.
  static const int _maxBlocks = 36;

  /// The `BITPIX` values FITS permits (integers + IEEE floats).
  static const Set<int> _allowedBitpix = {8, 16, 32, 64, -32, -64};

  /// Upper bound on the number of pixels [validatePixelSanity] samples, so the
  /// gate is O(1) in image size rather than reading every pixel of a large
  /// master.
  static const int _maxSamples = 4096;

  /// Number of bytes per pixel for the declared [bitpix].
  int get bytesPerPixel => bitpix.abs() ~/ 8;

  /// Total pixel count across all planes (`NAXIS1 * NAXIS2 * NAXIS3`).
  int get pixelCount => naxis1 * naxis2 * naxis3;

  /// Expected size of the pixel-data section, in bytes.
  int get dataBytes => pixelCount * bytesPerPixel;

  /// Parse the primary-HDU header of [bytes] and bounds-check its pixel data, or
  /// throw [FitsValidationError] when the bytes are not a backed 2-D FITS image
  /// (no `SIMPLE = T`, missing/invalid `BITPIX`/`NAXIS`, an END-less / truncated
  /// header, or a data section too short for the declared geometry — the
  /// header-only / undersized poison case).
  static FitsMasterHeader parse(Uint8List bytes) {
    final headers = <String, String>{};
    var sawEnd = false;
    var dataOffset = 0;
    final maxBytes = _maxBlocks * _blockSize;
    for (
      var base = 0;
      base < bytes.length && base < maxBytes;
      base += _blockSize
    ) {
      if (base + _blockSize > bytes.length) {
        throw FitsValidationError(
          'truncatedHeader',
          'master FITS header is truncated',
        );
      }
      for (var off = base; off < base + _blockSize; off += _cardSize) {
        final card = String.fromCharCodes(bytes, off, off + _cardSize);
        final keyword = card.substring(0, 8).trim();
        if (base == 0 && off == 0 && keyword != 'SIMPLE') {
          throw FitsValidationError(
            'notFits',
            'master body is not a FITS file (first card is "$keyword")',
          );
        }
        if (keyword == 'END') {
          sawEnd = true;
          // The pixel data starts at the next 2880-byte block boundary.
          dataOffset = base + _blockSize;
          break;
        }
        if (keyword.isEmpty ||
            keyword == 'COMMENT' ||
            keyword == 'HISTORY' ||
            card.length < 10 ||
            card[8] != '=') {
          continue;
        }
        headers[keyword] = _rawValue(card);
      }
      if (sawEnd) break;
    }
    if (!sawEnd) {
      throw FitsValidationError(
        'noEndCard',
        'master FITS header has no END card',
      );
    }

    if ((_int(headers, 'SIMPLE') == null && _bool(headers, 'SIMPLE') != true)) {
      throw FitsValidationError('notFits', 'master FITS is not SIMPLE = T');
    }
    final bitpix = _int(headers, 'BITPIX');
    if (bitpix == null || !_allowedBitpix.contains(bitpix)) {
      throw FitsValidationError(
        'badBitpix',
        'master FITS has an invalid BITPIX ($bitpix)',
      );
    }
    final naxis = _int(headers, 'NAXIS');
    if (naxis == null || naxis < 2) {
      throw FitsValidationError(
        'notImage',
        'master FITS is not a 2-D image (NAXIS=$naxis)',
      );
    }
    final naxis1 = _int(headers, 'NAXIS1');
    final naxis2 = _int(headers, 'NAXIS2');
    if (naxis1 == null || naxis2 == null || naxis1 <= 0 || naxis2 <= 0) {
      throw FitsValidationError(
        'badAxes',
        'master FITS has invalid image axes '
            '(NAXIS1=$naxis1, NAXIS2=$naxis2)',
      );
    }
    // A cube (NAXIS>=3) stacks planes; a plain image has no NAXIS3. A declared
    // NAXIS3<=0 is malformed.
    final naxis3 = naxis >= 3 ? (_int(headers, 'NAXIS3') ?? 1) : 1;
    if (naxis3 <= 0) {
      throw FitsValidationError(
        'badAxes',
        'master FITS has an invalid plane count (NAXIS3=$naxis3)',
      );
    }
    final bytesPerPixel = bitpix.abs() ~/ 8;
    final expectedData = naxis1 * naxis2 * naxis3 * bytesPerPixel;
    // The single hardest safety property here: the declared geometry must be
    // structurally backed by real pixel data. A header-only or undersized buffer
    // (the cheapest poison: a ~3 KB file advertising a popular sensor's exact
    // geometry) is rejected here.
    if (bytes.length < dataOffset + expectedData) {
      throw FitsValidationError(
        'truncatedData',
        'master FITS pixel data is missing or truncated: declared '
            '${naxis1}x$naxis2'
            '${naxis3 > 1 ? 'x$naxis3' : ''} at BITPIX $bitpix needs '
            '$expectedData data bytes but only ${bytes.length - dataOffset} '
            'are present',
      );
    }
    final frames = _int(headers, 'NFRAMES');
    return FitsMasterHeader(
      naxis1: naxis1,
      naxis2: naxis2,
      naxis3: naxis3,
      bitpix: bitpix,
      frameCount: (frames != null && frames > 0) ? frames : null,
      dataOffset: dataOffset,
    );
  }

  /// Statistical sanity gate on the pixel data of [bytes] (the same buffer
  /// [parse] validated). Throws [FitsValidationError] (`degenerateMaster`) when
  /// the master is structurally present but useless: an all-zero, all-saturated,
  /// or otherwise constant/degenerate buffer carries no calibration signal and is
  /// a classic poison upload. A real dark/bias/flat always has spatial structure
  /// (read noise, hot pixels, vignetting) and so a non-zero robust spread.
  ///
  /// Cost is bounded: it samples at most [_maxSamples] pixels spread across the
  /// frame (median + MAD, mirroring the federation `TileQualityGate`'s robust
  /// spread) rather than reading every pixel.
  void validatePixelSanity(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    final total = pixelCount;
    if (total <= 0) {
      throw FitsValidationError(
        'degenerateMaster',
        'master FITS declares no pixels',
      );
    }
    final stride = total <= _maxSamples ? 1 : total ~/ _maxSamples;
    final samples = <double>[];
    for (var i = 0; i < total; i += stride) {
      final offset = dataOffset + i * bytesPerPixel;
      if (offset + bytesPerPixel > bytes.length) break;
      samples.add(_readPixel(view, offset));
    }
    if (samples.length < 2) {
      throw FitsValidationError(
        'degenerateMaster',
        'master FITS has too few pixels to be a calibration master',
      );
    }
    final median = _median(samples);
    final mad = _medianAbsoluteDeviation(samples, median);
    // A zero robust spread means at least half the sampled pixels are identical
    // to the median — an all-zero / all-saturated / flat-filled buffer with no
    // calibration signal.
    if (mad == 0) {
      throw FitsValidationError(
        'degenerateMaster',
        'master FITS pixel data is degenerate (constant value '
            '${median.toStringAsFixed(median == median.roundToDouble() ? 0 : 3)}'
            ') — it carries no calibration signal',
      );
    }
  }

  double _readPixel(ByteData view, int offset) {
    switch (bitpix) {
      case 8:
        return view.getUint8(offset).toDouble();
      case 16:
        return view.getInt16(offset, Endian.big).toDouble();
      case 32:
        return view.getInt32(offset, Endian.big).toDouble();
      case 64:
        return view.getInt64(offset, Endian.big).toDouble();
      case -32:
        return view.getFloat32(offset, Endian.big);
      case -64:
        return view.getFloat64(offset, Endian.big);
      default:
        // parse() already rejected any other BITPIX.
        return view.getUint8(offset).toDouble();
    }
  }

  static double _median(List<double> values) {
    final sorted = List<double>.from(values)..sort();
    final n = sorted.length;
    if (n == 0) return 0;
    final mid = n ~/ 2;
    if (n.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  static double _medianAbsoluteDeviation(List<double> values, double center) {
    if (values.isEmpty) return 0;
    final dev = [for (final v in values) (v - center).abs()];
    return _median(dev);
  }

  static int? _int(Map<String, String> headers, String key) {
    final raw = headers[key]?.trim();
    if (raw == null || raw.isEmpty) return null;
    final asDouble = double.tryParse(raw);
    if (asDouble == null || !asDouble.isFinite) return null;
    return asDouble.round();
  }

  static bool? _bool(Map<String, String> headers, String key) {
    final raw = headers[key]?.trim();
    if (raw == null) return null;
    if (raw == 'T') return true;
    if (raw == 'F') return false;
    return null;
  }

  /// Strip the inline comment and return the raw value text of a card.
  static String _rawValue(String card) {
    final body = card.substring(10);
    if (body.trimLeft().startsWith("'")) {
      final start = body.indexOf("'");
      var i = start + 1;
      while (i < body.length) {
        if (body[i] == "'") {
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

/// A published master whose bytes fail FITS validation. Surfaced to the publish
/// handler as a [CalibrationPublishRejected]-equivalent 400.
class FitsValidationError implements Exception {
  FitsValidationError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'FitsValidationError($code): $message';
}
