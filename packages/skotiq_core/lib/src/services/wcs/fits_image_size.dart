import 'dart:io';

/// Width and height in pixels from a FITS primary header (NAXIS1, NAXIS2),
/// read without decoding the pixel data. Null when the file cannot be read or
/// the header names no positive size.
Future<({int width, int height})?> readFitsImageSize(String path) async {
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    int? width;
    int? height;
    // 36 cards per 2880-byte block; 64 blocks bounds a corrupt header.
    for (var block = 0; block < 64; block++) {
      final bytes = await file.read(2880);
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
  } on FileSystemException {
    return null;
  } finally {
    await file?.close();
  }
}
