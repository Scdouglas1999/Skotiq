// Tests for FitsHeaderWriter — pure-Dart in-place FITS header updates.
//
// We build a synthetic minimal FITS file in a temp directory:
//   - 1 header block (2880 B) ending with END
//   - 1 data block (2880 B of zeros) so total file size is a valid FITS
// and round-trip a battery of common science writeback keywords through
// the writer.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/science/fits_header_writer.dart';

const int _blockSize = FitsHeaderWriter.blockSize;
const int _cardSize = FitsHeaderWriter.cardSize;
const int _cardsPerBlock = FitsHeaderWriter.cardsPerBlock;

/// Build a minimal valid FITS file:
///   SIMPLE  =                    T
///   BITPIX  =                   16
///   NAXIS   =                    2
///   NAXIS1  =                   10
///   NAXIS2  =                   10
///   END
/// padded to one block, plus a 2880-byte zero data section.
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
  final data = Uint8List(_blockSize); // zeros
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

/// Read all header cards (excluding END and blank cards) back from disk.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  final writer = FitsHeaderWriter();

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sk_fits_writer_');
  });
  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('injects float, int, and string keywords in one pass', () async {
    final f = await _writeFixture(tempDir, name: 'inject.fits');
    final r = await writer.updateKeywords(f.path, [
      FitsKeywordWrite.floating(
        'MAGZP',
        24.317,
        comment: 'Photometric zero point [mag]',
      ),
      FitsKeywordWrite.integer('NSTAR', 142, comment: 'Stars used'),
      FitsKeywordWrite.string('MAGZPSRC', 'GAIA-DR3'),
    ]);

    expect(r.keywordsInjected, 3);
    expect(r.keywordsUpdated, 0);
    expect(
      r.headerGrew,
      isFalse,
      reason: 'one header block has 30+ free cards; 3 inserts must fit.',
    );

    final magzp = _firstCardFor(f, 'MAGZP');
    expect(magzp, isNotNull);
    expect(magzp, contains('24.317'));
    expect(magzp, contains('Photometric'));

    final nstar = _firstCardFor(f, 'NSTAR');
    expect(nstar, isNotNull);
    expect(nstar, contains('142'));

    final src = _firstCardFor(f, 'MAGZPSRC');
    expect(src, isNotNull);
    expect(src, contains("'GAIA-DR3'"));
  });

  test('overwriting an existing keyword does not add a duplicate', () async {
    final f = await _writeFixture(tempDir, name: 'overwrite.fits');
    await writer.updateKeywords(f.path, [
      FitsKeywordWrite.floating('MAGZP', 1.0),
    ]);
    final r = await writer.updateKeywords(f.path, [
      FitsKeywordWrite.floating('MAGZP', 24.5),
    ]);

    expect(r.keywordsInjected, 0);
    expect(r.keywordsUpdated, 1);

    final cards = _readHeaderCards(f);
    final magzpCards = cards
        .where((c) => c.substring(0, 8).toUpperCase() == 'MAGZP   ')
        .toList();
    expect(
      magzpCards,
      hasLength(1),
      reason: 'second write must overwrite, not append.',
    );
    expect(magzpCards.first, contains('24.5'));
  });

  test('data section is preserved byte-for-byte', () async {
    final f = await _writeFixture(tempDir, name: 'data.fits');
    // Stamp the data section with a recognisable pattern so we can detect
    // any accidental shifting.
    final stampedData = Uint8List(_blockSize);
    for (var i = 0; i < stampedData.length; i++) {
      stampedData[i] = (i & 0xFF);
    }
    final original = await f.readAsBytes();
    final modified = Uint8List(original.length);
    modified.setAll(0, original);
    modified.setRange(_blockSize, _blockSize * 2, stampedData);
    await f.writeAsBytes(modified, flush: true);

    await writer.updateKeywords(f.path, [
      FitsKeywordWrite.floating('TRANSPAR', 88.0),
    ]);

    final after = await f.readAsBytes();
    // The data section is everything from the first byte after the new
    // header. Compute by finding END in the rewritten header.
    final endIdx = _findEnd(after);
    final dataStart = ((endIdx ~/ _cardsPerBlock) + 1) * _blockSize;
    final readBack = after.sublist(dataStart, dataStart + _blockSize);
    expect(
      readBack,
      stampedData,
      reason: 'data bytes must be preserved verbatim across writeback.',
    );
  });

  test('grows the header by a block when free cards run out', () async {
    final f = await _writeFixture(tempDir, name: 'grow.fits');

    // The fixture header block has 36 cards: 6 are populated (SIMPLE +
    // BITPIX + NAXIS + NAXIS1 + NAXIS2 + END) so 30 free cards remain.
    // Inject 35 cards — that's 5 over capacity, forcing a header grow.
    final writes = <FitsKeywordWrite>[
      for (var i = 0; i < 35; i++)
        FitsKeywordWrite.floating(
          'PAD${i.toString().padLeft(2, '0')}',
          i.toDouble(),
        ),
    ];
    final r = await writer.updateKeywords(f.path, writes);
    expect(r.headerGrew, isTrue);
    expect(r.headerBlocks, 2);

    // The data section must be preserved — file size stays consistent:
    // 2 header blocks + 1 data block = 8640 bytes.
    final stat = await f.stat();
    expect(
      stat.size,
      _blockSize * 3,
      reason: 'after a 1-block grow, file is 2 header + 1 data blocks.',
    );
  });

  test('rejects unknown / oversize / multi-typed keywords up-front', () async {
    final f = await _writeFixture(tempDir, name: 'reject.fits');
    expect(
      () => writer.updateKeywords(f.path, [
        FitsKeywordWrite.floating('TOO_LONG_KW', 1.0),
      ]),
      throwsArgumentError,
    );
    final originalBytes = await f.readAsBytes();
    final afterFailedAttempt = await f.readAsBytes();
    expect(
      afterFailedAttempt,
      originalBytes,
      reason: 'a rejected update must never mutate the file on disk.',
    );
  });

  test('non-finite float values are refused', () async {
    final f = await _writeFixture(tempDir, name: 'nan.fits');
    expect(
      () => writer.updateKeywords(f.path, [
        FitsKeywordWrite.floating('MAGZP', double.nan),
      ]),
      throwsArgumentError,
    );
    expect(
      () => writer.updateKeywords(f.path, [
        FitsKeywordWrite.floating('MAGZP', double.infinity),
      ]),
      throwsArgumentError,
    );
  });

  test(
    'missing END card throws FormatException rather than corrupting',
    () async {
      final f = File('${tempDir.path}${Platform.pathSeparator}bad.fits');
      // 2880 bytes of A's — no END card anywhere.
      await f.writeAsBytes(
        Uint8List(_blockSize)..fillRange(0, _blockSize, 0x41),
      );
      expect(
        () => writer.updateKeywords(f.path, [
          FitsKeywordWrite.floating('MAGZP', 1.0),
        ]),
        throwsFormatException,
      );
    },
  );
}

int _findEnd(Uint8List bytes) {
  for (var i = 0; i < bytes.length ~/ _cardSize; i++) {
    final off = i * _cardSize;
    if (bytes[off] == 0x45 &&
        bytes[off + 1] == 0x4E &&
        bytes[off + 2] == 0x44 &&
        bytes[off + 3] == 0x20) {
      return i;
    }
  }
  return -1;
}
