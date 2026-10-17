// Dark library FITS parser must accept float32 and float64 master
// darks (the formats produced by NINA, PixInsight, and SiriL), in addition to
// the existing 16-bit path.
//
// These tests exercise the parser through `loadDarkPixels`, which is the
// public surface that wraps `_parseFitsPixels`. Each test builds a synthetic
// FITS file with known pixel values and checks that the parser returns the
// expected u16 representation.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show DarkLibraryDao, DarkLibraryService, SkotiqDatabase;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DarkLibraryService FITS parser — float32 / float64 support', () {
    late Directory tempDir;
    late DarkLibraryService service;
    late SkotiqDatabase database;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('dark_library_fits_');
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      service = DarkLibraryService(DarkLibraryDao(database));
    });

    tearDown(() async {
      await database.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    Future<File> writeFits(String name, Uint8List bytes) async {
      final f = File('${tempDir.path}${Platform.pathSeparator}$name');
      await f.writeAsBytes(bytes);
      return f;
    }

    test(
      'regression: existing BITPIX=16 path still decodes signed-with-BZERO=32768 '
      'darks correctly',
      () async {
        // Build a 2x1 16-bit FITS frame with the historical unsigned-via-signed
        // encoding. Pixel 0 stored as signed -32768 (=> physical 0), pixel 1
        // stored as signed +32767 (=> physical 65535).
        final data = Uint8List(4);
        // -32768 signed = 0x8000 big-endian
        data[0] = 0x80;
        data[1] = 0x00;
        // +32767 signed = 0x7FFF big-endian
        data[2] = 0x7F;
        data[3] = 0xFF;

        final fits = _buildFits16(width: 2, height: 1, pixelBytes: data);
        final file = await writeFits('uint16.fit', fits);

        final pixels = await service.loadDarkPixels(file.path);

        expect(pixels.length, 2);
        expect(pixels[0], 0);
        expect(pixels[1], 65535);
      },
    );

    test(
      'BITPIX=-32: float32 FITS decodes through clamp+round to u16',
      () async {
        // Four pixels: 0.0, 12345.5, 65535.0, and -1.0 (will saturate to 0).
        final values = <double>[0.0, 12345.5, 65535.0, -1.0];
        final fits = _buildFitsFloat32(
          values: values,
          bzero: null,
          bscale: null,
        );
        final file = await writeFits('float32.fit', fits);

        final pixels = await service.loadDarkPixels(file.path);

        expect(pixels.length, 4);
        expect(pixels[0], 0);
        // 12345.5 rounds-half-away-from-zero to 12346 in our implementation
        // (we use floor(x + 0.5)).
        expect(pixels[1], 12346);
        expect(pixels[2], 65535);
        // -1.0 saturates to 0 (loud warning is logged by the service).
        expect(pixels[3], 0);
      },
    );

    test(
      'BITPIX=-32: BZERO/BSCALE linear transform is applied per FITS spec',
      () async {
        // Encode physical = 100*stored + 1000 → stored=0.5 should give 1050.
        // Four pixels chosen to exercise the transform in the mid-range and
        // at both saturation edges.
        final values = <double>[
          0.0, // physical = 1000 → u16 1000
          0.5, // physical = 1050 → u16 1050
          640.35, // physical = 65035 → u16 65035
          1000.0, // physical = 101000 → saturates high → u16 65535
        ];
        final fits = _buildFitsFloat32(
          values: values,
          bzero: 1000.0,
          bscale: 100.0,
        );
        final file = await writeFits('float32_scaled.fit', fits);

        final pixels = await service.loadDarkPixels(file.path);

        expect(pixels[0], 1000);
        expect(pixels[1], 1050);
        expect(pixels[2], 65035);
        expect(pixels[3], 65535);
      },
    );

    test(
      'BZERO=32768 + signed-range float values produces [0..65535] unsigned',
      () async {
        // Mimic the classic "use BZERO to encode unsigned" trick but with
        // float storage: stored ∈ [-32768, 32767], BZERO=32768, BSCALE=1
        // should land at u16 [0, 65535].
        final values = <double>[
          -32768.0, // → 0
          0.0, // → 32768
          32767.0, // → 65535
        ];
        final fits = _buildFitsFloat32(
          values: values,
          bzero: 32768.0,
          bscale: 1.0,
        );
        final file = await writeFits('float32_bzero32768.fit', fits);

        final pixels = await service.loadDarkPixels(file.path);

        expect(pixels[0], 0);
        expect(pixels[1], 32768);
        expect(pixels[2], 65535);
      },
    );

    test(
      'BITPIX=-64: float64 FITS decodes through clamp+round to u16',
      () async {
        // Pick values that would not survive a float32 round-trip exactly, to
        // confirm we are actually using float64 (8-byte) decoding.
        final values = <double>[
          0.0,
          1.0 / 3.0 * 65535.0, // 21845.0
          65535.0,
          70000.0, // saturates high
        ];
        final fits = _buildFitsFloat64(
          values: values,
          bzero: null,
          bscale: null,
        );
        final file = await writeFits('float64.fit', fits);

        final pixels = await service.loadDarkPixels(file.path);

        expect(pixels.length, 4);
        expect(pixels[0], 0);
        // 21845.0 ± rounding → 21845 exactly
        expect(pixels[1], 21845);
        expect(pixels[2], 65535);
        expect(pixels[3], 65535);
      },
    );

    test(
      'BITPIX=-32 NaN samples collapse to 0 instead of poisoning the buffer',
      () async {
        final values = <double>[double.nan, 100.0];
        final fits = _buildFitsFloat32(
          values: values,
          bzero: null,
          bscale: null,
        );
        final file = await writeFits('float32_nan.fit', fits);

        final pixels = await service.loadDarkPixels(file.path);

        expect(pixels[0], 0);
        expect(pixels[1], 100);
      },
    );

    test('Unsupported BITPIX is rejected with a descriptive error listing the '
        'supported encodings', () async {
      // BITPIX=8 (unsigned byte) is valid FITS but not accepted by the dark
      // library; the error MUST list the supported values so the user can
      // fix their pipeline rather than guess.
      final fits = _buildFitsHeaderOnly(
        width: 4,
        height: 1,
        bitpix: 8,
        extraCards: const [],
        dataBytes: Uint8List(4),
      );
      final file = await writeFits('bitpix8.fit', fits);

      await expectLater(
        service.loadDarkPixels(file.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Unsupported FITS BITPIX=8'),
              contains('16'),
              contains('-32'),
              contains('-64'),
            ),
          ),
        ),
      );
    });

    test('Unsupported BITPIX=-16 is also rejected loudly', () async {
      // -16 isn't a real FITS encoding but exercises the "any other value"
      // branch with a number that isn't in the allowed list.
      final fits = _buildFitsHeaderOnly(
        width: 2,
        height: 1,
        bitpix: -16,
        extraCards: const [],
        dataBytes: Uint8List(4),
      );
      final file = await writeFits('bitpix_neg16.fit', fits);

      await expectLater(
        service.loadDarkPixels(file.path),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Unsupported FITS BITPIX=-16'),
          ),
        ),
      );
    });

    test('Truncated float32 payload still throws FormatException', () async {
      // Build a header that promises 4 pixels of float32 (16 bytes of data)
      // but only supply 8 bytes.
      final fits = _buildFitsHeaderOnly(
        width: 4,
        height: 1,
        bitpix: -32,
        extraCards: const [],
        dataBytes: Uint8List(8), // half the expected payload
      );
      final file = await writeFits('float32_truncated.fit', fits);

      await expectLater(
        service.loadDarkPixels(file.path),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

// Synthetic FITS builders

/// Build a complete FITS file with BITPIX=16 and the given raw big-endian
/// signed-16 payload (caller is responsible for encoding the BZERO=32768
/// offset, so we can test the parser's existing 16-bit path verbatim).
Uint8List _buildFits16({
  required int width,
  required int height,
  required Uint8List pixelBytes,
}) {
  final cards = <String>[
    _fitsCard('SIMPLE', 'T'),
    _fitsCard('BITPIX', '16'),
    _fitsCard('NAXIS', '2'),
    _fitsCard('NAXIS1', width.toString()),
    _fitsCard('NAXIS2', height.toString()),
    _fitsCard('BZERO', '32768'),
    _fitsCard('BSCALE', '1'),
    'END'.padRight(80, ' '),
  ];
  return _assembleFits(cards: cards, dataBytes: pixelBytes);
}

Uint8List _buildFitsFloat32({
  required List<double> values,
  required double? bzero,
  required double? bscale,
}) {
  final data = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    data.setFloat32(i * 4, values[i], Endian.big);
  }
  final extra = <String>[
    if (bzero != null) _fitsCard('BZERO', bzero.toString()),
    if (bscale != null) _fitsCard('BSCALE', bscale.toString()),
  ];
  return _buildFitsHeaderOnly(
    width: values.length,
    height: 1,
    bitpix: -32,
    extraCards: extra,
    dataBytes: data.buffer.asUint8List(),
  );
}

Uint8List _buildFitsFloat64({
  required List<double> values,
  required double? bzero,
  required double? bscale,
}) {
  final data = ByteData(values.length * 8);
  for (var i = 0; i < values.length; i++) {
    data.setFloat64(i * 8, values[i], Endian.big);
  }
  final extra = <String>[
    if (bzero != null) _fitsCard('BZERO', bzero.toString()),
    if (bscale != null) _fitsCard('BSCALE', bscale.toString()),
  ];
  return _buildFitsHeaderOnly(
    width: values.length,
    height: 1,
    bitpix: -64,
    extraCards: extra,
    dataBytes: data.buffer.asUint8List(),
  );
}

Uint8List _buildFitsHeaderOnly({
  required int width,
  required int height,
  required int bitpix,
  required List<String> extraCards,
  required Uint8List dataBytes,
}) {
  final cards = <String>[
    _fitsCard('SIMPLE', 'T'),
    _fitsCard('BITPIX', bitpix.toString()),
    _fitsCard('NAXIS', '2'),
    _fitsCard('NAXIS1', width.toString()),
    _fitsCard('NAXIS2', height.toString()),
    ...extraCards,
    'END'.padRight(80, ' '),
  ];
  return _assembleFits(cards: cards, dataBytes: dataBytes);
}

Uint8List _assembleFits({
  required List<String> cards,
  required Uint8List dataBytes,
}) {
  final headerStr = cards.join().padRight(2880, ' ');
  // Pad header to a 2880-byte block boundary.
  final paddedHeaderLen = ((headerStr.length + 2879) ~/ 2880) * 2880;
  final fullHeader = headerStr.padRight(paddedHeaderLen, ' ');
  final headerBytes = ascii.encode(fullHeader);
  final out = BytesBuilder(copy: false)
    ..add(headerBytes)
    ..add(dataBytes);
  return out.toBytes();
}

String _fitsCard(String keyword, String value) {
  return '${keyword.padRight(8)}= ${value.padLeft(20)}'.padRight(80, ' ');
}
