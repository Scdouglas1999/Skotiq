// End-to-end FITS writeback contract test.
//
// The science processing pipeline's writeback stage has two parts:
//   1. Build a list of `FitsKeywordWrite` from a `FramePhotometricCalibration`
//      and `TransparencySample`. This is exposed publicly as
//      `ScienceProcessingService.buildScienceWritebackKeywords` precisely so
//      it can be tested in isolation from Riverpod, the database, and the
//      native bridge.
//   2. Round-trip those keywords through `FitsHeaderWriter` so external
//      tools (PixInsight, AstroPixelProcessor, Siril) can read them.
//
// This test exercises both parts against a real (synthetic) FITS fixture on
// disk. Renaming a keyword, swapping a unit, dropping the NSHA_VER provenance
// stamp, or breaking the writer's atomic file replacement fails it loudly.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

const int _blockSize = FitsHeaderWriter.blockSize;
const int _cardSize = FitsHeaderWriter.cardSize;
const int _cardsPerBlock = FitsHeaderWriter.cardsPerBlock;

Future<File> _writeFixture(Directory dir, {required String name}) async {
  final cards = <String>[
    _card('SIMPLE', '                   T'),
    _card('BITPIX', '                  16'),
    _card('NAXIS', '                   2'),
    _card('NAXIS1', '                  10'),
    _card('NAXIS2', '                  10'),
    'END'.padRight(_cardSize, ' '),
  ];
  while (cards.length < _cardsPerBlock) {
    cards.add(' ' * _cardSize);
  }
  final header = cards.join('').codeUnits;
  // 10*10 int16 = 200 bytes of "image data" — fits within a single
  // 2880-byte data block. We just zero-fill; the writer never inspects it.
  final data = Uint8List(_blockSize);
  final all = Uint8List.fromList([...header, ...data]);
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(all, flush: true);
  return file;
}

String _card(String key, String body) {
  final left = key.padRight(8, ' ');
  final remainder = '= $body';
  final padded = remainder.padRight(_cardSize - 8, ' ');
  return '$left$padded';
}

List<String> _readHeaderCards(File f) {
  final bytes = f.readAsBytesSync();
  final result = <String>[];
  for (var i = 0; i < bytes.length ~/ _cardSize; i++) {
    final off = i * _cardSize;
    final card = String.fromCharCodes(bytes.sublist(off, off + _cardSize));
    if (card.startsWith('END     ')) break;
    if (card.trim().isEmpty) continue;
    result.add(card);
  }
  return result;
}

String? _firstCardFor(File f, String key) {
  final upper = key.toUpperCase().padRight(8);
  for (final c in _readHeaderCards(f)) {
    if (c.substring(0, 8).toUpperCase() == upper) return c;
  }
  return null;
}

double _floatFromCard(String card) {
  final body = card.substring(10);
  final slash = body.indexOf('/');
  final value = (slash < 0 ? body : body.substring(0, slash)).trim();
  return double.parse(value);
}

int _intFromCard(String card) {
  final body = card.substring(10);
  final slash = body.indexOf('/');
  final value = (slash < 0 ? body : body.substring(0, slash)).trim();
  return int.parse(value);
}

String _stringFromCard(String card) {
  final body = card.substring(10);
  final slash = body.indexOf('/');
  final value = (slash < 0 ? body : body.substring(0, slash)).trim();
  // FITS strings are wrapped in single quotes.
  return value.startsWith("'") && value.endsWith("'")
      ? value.substring(1, value.length - 1).trim()
      : value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  final writer = FitsHeaderWriter();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ns_science_e2e_');
  });
  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'full pipeline contract: calibration + transparency round-trip',
    () async {
      final cal = FramePhotometricCalibration(
        capturedImageId: 42,
        sessionId: 7,
        timestamp: DateTime.utc(2026, 1, 1, 22, 30),
        isCalibrated: true,
        zeroPoint: 24.317,
        limitingMag5Sigma: 20.85,
        matchedStarCount: 142,
        calibrationRms: 0.039,
        solverId: 'skotiq',
        catalogSource: PhotometricCatalogSource.localGaia,
        exposureSeconds: 120.0,
      );
      final transparency = TransparencySample(
        capturedImageId: 42,
        sessionId: 7,
        timestamp: DateTime.utc(2026, 1, 1, 22, 30),
        transparencyPercent: 87.4,
        extinctionCoefficient: 0.215,
        qualityBucket: 'good',
        confidence: 0.78,
        // EXTINCT is unit-bearing (mag/airmass) and only stamped when the
        // value came from a real ZP-vs-airmass regression.
        extinctionFromAirmassFit: true,
      );

      final updates = ScienceProcessingService.buildScienceWritebackKeywords(
        calibration: cal,
        transparency: transparency,
        buildTag: 'Skotiq 2.5.0',
      );

      // Pre-write expectations: every keyword the science contract promises
      // must be present in the build set.
      expect(updates.map((u) => u.keyword).toList(), [
        'MAGZP',
        'MAGZPERR',
        'MAGZPSRC',
        'MAGZPNST',
        'MAGLIM5',
        'TRANSPAR',
        'EXTINCT',
        'NSHA_VER',
      ]);

      final fixture = await _writeFixture(tempDir, name: 'e2e.fits');
      final result = await writer.updateKeywords(fixture.path, updates);
      expect(result.keywordsInjected, updates.length);
      expect(result.keywordsUpdated, 0);

      // Read back and verify every value made it through the round-trip with
      // sane formatting / rounding.
      final magzp = _firstCardFor(fixture, 'MAGZP');
      expect(magzp, isNotNull);
      expect(_floatFromCard(magzp!), closeTo(24.317, 1e-6));
      expect(magzp, contains('Photometric zero point'));

      final magzperr = _firstCardFor(fixture, 'MAGZPERR');
      expect(magzperr, isNotNull);
      expect(_floatFromCard(magzperr!), closeTo(0.039, 1e-6));

      final magzpsrc = _firstCardFor(fixture, 'MAGZPSRC');
      expect(magzpsrc, isNotNull);
      expect(_stringFromCard(magzpsrc!), 'LOCALGAIA');

      final magzpnst = _firstCardFor(fixture, 'MAGZPNST');
      expect(magzpnst, isNotNull);
      expect(_intFromCard(magzpnst!), 142);

      final maglim5 = _firstCardFor(fixture, 'MAGLIM5');
      expect(maglim5, isNotNull);
      expect(_floatFromCard(maglim5!), closeTo(20.85, 1e-6));

      final transpar = _firstCardFor(fixture, 'TRANSPAR');
      expect(transpar, isNotNull);
      expect(_floatFromCard(transpar!), closeTo(87.4, 1e-6));

      final extinct = _firstCardFor(fixture, 'EXTINCT');
      expect(extinct, isNotNull);
      expect(_floatFromCard(extinct!), closeTo(0.215, 1e-6));

      final nshaVer = _firstCardFor(fixture, 'NSHA_VER');
      expect(nshaVer, isNotNull);
      expect(_stringFromCard(nshaVer!), 'Skotiq 2.5.0');

      // Data section must be preserved byte-for-byte. The fixture was 1
      // header block + 1 data block; after writeback the data should still
      // be exactly _blockSize zeroes at the file's data offset (which we can
      // compute by stepping past every header block until the END card).
      final bytes = await fixture.readAsBytes();
      var headerBytes = 0;
      while (headerBytes < bytes.length) {
        final block = bytes.sublist(headerBytes, headerBytes + _blockSize);
        headerBytes += _blockSize;
        final blockStr = String.fromCharCodes(block);
        if (blockStr.contains(RegExp(r'END\s+'))) break;
      }
      expect(
        bytes.length - headerBytes,
        _blockSize,
        reason: 'data section must remain exactly one 2880-byte block',
      );
      for (var i = headerBytes; i < bytes.length; i++) {
        expect(
          bytes[i],
          0,
          reason: 'data byte at offset $i must be untouched after writeback',
        );
      }
    },
  );

  test(
    'empty contract: no calibration and no transparency means no writes',
    () async {
      final updates = ScienceProcessingService.buildScienceWritebackKeywords(
        calibration: null,
        transparency: null,
      );
      expect(
        updates,
        isEmpty,
        reason: 'writeback must short-circuit when nothing useful was produced',
      );
    },
  );

  test('partial contract: transparency-only still stamps NSHA_VER', () async {
    final updates = ScienceProcessingService.buildScienceWritebackKeywords(
      calibration: null,
      transparency: TransparencySample(
        capturedImageId: null,
        sessionId: null,
        timestamp: DateTime.utc(2026, 1, 1),
        transparencyPercent: 64.0,
        extinctionCoefficient: 0.41,
        qualityBucket: 'fair',
        confidence: 0.55,
        extinctionFromAirmassFit: true,
      ),
    );
    expect(updates.map((u) => u.keyword).toList(), [
      'TRANSPAR',
      'EXTINCT',
      'NSHA_VER',
    ]);
  });

  test(
    'warm-up transparency (no airmass fit) must NOT stamp EXTINCT — the '
    'fallback value is a baseline ZP depression in mag, not mag/airmass',
    () async {
      final updates = ScienceProcessingService.buildScienceWritebackKeywords(
        calibration: null,
        transparency: TransparencySample(
          capturedImageId: null,
          sessionId: null,
          timestamp: DateTime.utc(2026, 1, 1),
          transparencyPercent: 64.0,
          extinctionCoefficient: 0.41,
          qualityBucket: 'fair',
          confidence: 0.55,
        ),
      );
      expect(updates.map((u) => u.keyword).toList(), ['TRANSPAR', 'NSHA_VER']);
    },
  );

  test('infinite values are silently dropped, never written', () async {
    final updates = ScienceProcessingService.buildScienceWritebackKeywords(
      calibration: FramePhotometricCalibration(
        capturedImageId: 1,
        sessionId: 1,
        timestamp: DateTime.utc(2026, 1, 1),
        isCalibrated: true,
        zeroPoint: double.infinity,
        limitingMag5Sigma: double.nan,
        matchedStarCount: 10,
        calibrationRms: 0.1,
        solverId: 'skotiq',
        catalogSource: PhotometricCatalogSource.localApass,
      ),
      transparency: null,
    );
    // Non-finite MAGZP and MAGLIM5 are dropped — but MAGZPSRC/MAGZPNST/MAGZPERR
    // remain since they ARE finite. We still stamp provenance.
    final keywords = updates.map((u) => u.keyword).toList();
    expect(keywords, contains('MAGZPSRC'));
    expect(keywords, contains('MAGZPNST'));
    expect(keywords, contains('MAGZPERR'));
    expect(keywords, contains('NSHA_VER'));
    expect(keywords, isNot(contains('MAGZP')));
    expect(keywords, isNot(contains('MAGLIM5')));
  });
}
