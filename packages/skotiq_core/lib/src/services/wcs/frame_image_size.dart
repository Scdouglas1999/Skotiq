import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Width and height in pixels of a FITS or XISF frame, read from its header
/// without decoding the pixel data. Null when the file cannot be read or the
/// header names no positive size.
Future<({int width, int height})?> readFrameImageSize(String path) async {
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    final head = await file.read(2880);
    if (_startsWith(head, 'XISF0100')) return await _xisfSize(file, head);
    return await _fitsSize(file, head);
  } on FileSystemException {
    return null;
  } finally {
    await file?.close();
  }
}

bool _startsWith(Uint8List bytes, String text) =>
    bytes.length >= text.length &&
    String.fromCharCodes(bytes, 0, text.length) == text;

/// NAXIS1 and NAXIS2 of the primary header.
Future<({int width, int height})?> _fitsSize(
  RandomAccessFile file,
  Uint8List first,
) async {
  int? width;
  int? height;
  var bytes = first;
  // 36 cards per 2880-byte block; 64 blocks bounds a corrupt header.
  for (var block = 0; block < 64; block++) {
    if (block > 0) bytes = await file.read(2880);
    if (bytes.length < 2880) return null;
    for (var at = 0; at + 80 <= bytes.length; at += 80) {
      final card = String.fromCharCodes(bytes, at, at + 80);
      final key = card.substring(0, 8).trim();
      if (key == 'END') {
        if (width != null && height != null && width > 0 && height > 0) {
          return (width: width, height: height);
        }
        return null;
      }
      if (card.length < 10 || card[8] != '=') continue;
      if (key != 'NAXIS1' && key != 'NAXIS2') continue;
      final value = int.tryParse(card.substring(10).split('/').first.trim());
      if (key == 'NAXIS1') width = value;
      if (key == 'NAXIS2') height = value;
    }
  }
  return null;
}

/// The geometry of the first Image element of a monolithic XISF file.
Future<({int width, int height})?> _xisfSize(
  RandomAccessFile file,
  Uint8List first,
) async {
  if (first.length < 16) return null;
  final length = ByteData.sublistView(first, 8, 12).getUint32(0, Endian.little);
  // The geometry sits near the start of any real header; a bound keeps a
  // corrupt length from reading the whole file.
  final wanted = length.clamp(0, 1 << 20);
  await file.setPosition(16);
  final xml = utf8.decode(await file.read(wanted), allowMalformed: true);
  final match = RegExp(
    r'<Image\b[^>]*?\bgeometry="\s*(\d+)\s*:\s*(\d+)',
  ).firstMatch(xml);
  if (match == null) return null;
  final width = int.parse(match.group(1)!);
  final height = int.parse(match.group(2)!);
  if (width <= 0 || height <= 0) return null;
  return (width: width, height: height);
}
