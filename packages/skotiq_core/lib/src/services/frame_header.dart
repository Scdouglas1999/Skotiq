import 'dart:typed_data';

import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

import 'wcs/gnomonic_projection.dart';

/// What a frame file's header says: its cards and the astrometry they state.
///
/// Read by the native frame reader ([readFrameHeader]), so a FITS, XISF or
/// camera raw file means here what it means to every native reader of it:
/// long strings, HIERARCH names, XISF properties and every form of WCS.
class FrameHeader {
  /// A header of [values] by keyword, each a `String` or a `num`.
  FrameHeader(Map<String, Object> values, {this.astrometry})
    : _text = {
        for (final MapEntry(:key, :value) in values.entries)
          key.toUpperCase(): '$value',
      },
      _numbers = {
        for (final MapEntry(:key, :value) in values.entries)
          if (value is num) key.toUpperCase(): value.toDouble(),
      };

  FrameHeader._read(bridge.FrameHeaderRead read)
    : _text = {for (final card in read.cards) card.keyword: card.text},
      _numbers = {
        for (final card in read.cards)
          if (card.number case final number?) card.keyword: number,
      },
      astrometry = read.wcs;

  final Map<String, String> _text;
  final Map<String, double> _numbers;

  /// The astrometry the header states, as written; null when it states none.
  final bridge.FrameWcs? astrometry;

  /// The text of [keyword]'s value, trimmed; null when absent or blank.
  String? string(String keyword) {
    final text = _text[keyword]?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  /// [keyword]'s value when it is a number.
  double? number(String keyword) => _numbers[keyword];

  /// [keyword]'s value rounded to a whole number.
  int? integer(String keyword) {
    final value = number(keyword);
    return value == null || !value.isFinite ? null : value.round();
  }

  /// The first of [keywords] that holds a number, for names that say one
  /// thing (`EXPTIME`, `EXPOSURE`).
  double? firstNumber(List<String> keywords) {
    for (final keyword in keywords) {
      if (number(keyword) case final value?) return value;
    }
    return null;
  }

  /// Width and height in pixels; null when the header states no positive size.
  ({int width, int height})? get imageSize {
    final width = integer('NAXIS1');
    final height = integer('NAXIS2');
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return (width: width, height: height);
  }

  /// Color planes: `NAXIS3`, one when absent.
  int get channels => integer('NAXIS3') ?? 1;

  /// The frame's astrometry over its own pixels; null when the header states
  /// none, states no size, or its matrix cannot be inverted.
  SolvedWcs? get solvedWcs {
    final wcs = astrometry;
    final size = imageSize;
    if (wcs == null || size == null) return null;
    return SolvedWcs.tryFromFits(
      crval1: wcs.crval1,
      crval2: wcs.crval2,
      crpix1: wcs.crpix1,
      crpix2: wcs.crpix2,
      cd1_1: wcs.cd11,
      cd1_2: wcs.cd12,
      cd2_1: wcs.cd21,
      cd2_2: wcs.cd22,
      sip: (
        aOrder: wcs.aOrder,
        bOrder: wcs.bOrder,
        aCoeffs: wcs.aCoeffs.toList(growable: false),
        bCoeffs: wcs.bCoeffs.toList(growable: false),
        apOrder: wcs.apOrder,
        bpOrder: wcs.bpOrder,
        apCoeffs: wcs.apCoeffs.toList(growable: false),
        bpCoeffs: wcs.bpCoeffs.toList(growable: false),
      ),
      imageWidth: size.width,
      imageHeight: size.height,
    );
  }
}

/// Reads the header of the frame file at a path.
typedef FrameHeaderReader = Future<FrameHeader> Function(String path);

/// The header of the frame file at [path], without decoding its pixels.
///
/// Throws [bridge.SkotiqError] when the file cannot be read or is no frame.
Future<FrameHeader> readFrameHeader(String path) async =>
    FrameHeader._read(await bridge.apiReadFrameHeader(filePath: path));

/// Writes a solution into the frame file at a path as its astrometry.
typedef FrameWcsWriter = Future<void> Function(String path, SolvedWcs wcs);

/// Write [wcs] into the frame file at [path] as its astrometry, in place of
/// any it held; its pixels and other cards stay as they are.
Future<void> writeFrameWcs(String path, SolvedWcs wcs) {
  final fits = wcs.fitsTerms;
  final sip = wcs.sip;
  return bridge.apiWriteFrameWcs(
    filePath: path,
    wcs: bridge.FrameWcs(
      crval1: fits.crval1,
      crval2: fits.crval2,
      crpix1: fits.crpix1,
      crpix2: fits.crpix2,
      cd11: fits.cd1_1,
      cd12: fits.cd1_2,
      cd21: fits.cd2_1,
      cd22: fits.cd2_2,
      aOrder: sip.aOrder,
      bOrder: sip.bOrder,
      aCoeffs: Float64List.fromList(sip.aCoeffs),
      bCoeffs: Float64List.fromList(sip.bCoeffs),
      apOrder: sip.apOrder,
      bpOrder: sip.bpOrder,
      apCoeffs: Float64List.fromList(sip.apCoeffs),
      bpCoeffs: Float64List.fromList(sip.bpCoeffs),
    ),
  );
}
