import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/calibration/fits_header_reader.dart';

/// Builds a minimal valid FITS primary header (one or more 2880-byte blocks)
/// out of `KEYWORD = value / comment` card strings, terminated by `END`.
File _writeFits(Directory dir, String name, List<String> cards) {
  final all = <String>['SIMPLE  =                    T', ...cards, 'END'];
  final bytes = BytesBuilder();
  for (final card in all) {
    bytes.add(Uint8List.fromList(card.padRight(80).codeUnits));
  }
  // Pad the final block to a 2880-byte boundary with spaces.
  final remainder = bytes.length % 2880;
  if (remainder != 0) {
    bytes.add(Uint8List(2880 - remainder)..fillRange(0, 2880 - remainder, 32));
  }
  final file = File('${dir.path}/$name');
  file.writeAsBytesSync(bytes.toBytes());
  return file;
}

void main() {
  const reader = FitsHeaderReader();
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fits_reader_');
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('reads typed string / int / double primary-header values', () async {
    final file = _writeFits(dir, 'm.fits', [
      "INSTRUME= 'ASI2600MC Pro'      / camera",
      'GAIN    =                  100',
      'CCD-TEMP=                -10.5 / sensor temp',
      'EXPTIME =                300.0',
      "FILTER  = 'Ha      '",
    ]);

    final headers = await reader.readPrimaryHeader(file.path);
    expect(FitsHeaderReader.stringValue(headers, 'INSTRUME'), 'ASI2600MC Pro');
    expect(FitsHeaderReader.intValue(headers, 'GAIN'), 100);
    expect(
      FitsHeaderReader.doubleValue(headers, 'CCD-TEMP'),
      closeTo(-10.5, 1e-9),
    );
    expect(
      FitsHeaderReader.firstDouble(headers, const ['EXPOSURE', 'EXPTIME']),
      closeTo(300.0, 1e-9),
    );
    expect(FitsHeaderReader.stringValue(headers, 'FILTER'), 'Ha');
  });

  test('strips comments but keeps a "/" inside a quoted string', () async {
    final file = _writeFits(dir, 'c.fits', [
      "OBJECT  = 'NGC 7000 / pelican' / nickname",
    ]);
    final headers = await reader.readPrimaryHeader(file.path);
    expect(
      FitsHeaderReader.stringValue(headers, 'OBJECT'),
      'NGC 7000 / pelican',
    );
  });

  test('a non-FITS file throws FormatException', () async {
    final file = File('${dir.path}/notfits.bin');
    file.writeAsBytesSync(Uint8List(2880));
    expect(
      () => reader.readPrimaryHeader(file.path),
      throwsA(isA<FormatException>()),
    );
  });
}
