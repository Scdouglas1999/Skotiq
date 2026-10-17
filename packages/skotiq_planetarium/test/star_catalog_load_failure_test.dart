import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// A star catalog that fails to parse must not be reported as an empty sky.
///
/// The failure path used to `return []` without touching `_usingFallback` and
/// without caching anything, so the app drew a black chart, the "catalog not
/// installed" warning stayed silent because the flag was still false, and every
/// subsequent rebuild re-ran the whole 120k-row parse to fail again.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hyg_load_failure');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  /// A file that exists (so the missing-file branch is not taken) but whose
  /// bytes are not valid UTF-8, so the decoder throws inside the load isolate.
  Future<File> writeUndecodableCatalog() async {
    final file = File('${tempDir.path}/hygdata.csv');
    await file.writeAsBytes(<int>[
      ...'id,hip,hd\n'.codeUnits,
      0xC3, 0x28, // truncated multi-byte sequence
      0xA0, 0xA1,
      0x0A,
    ]);
    return file;
  }

  test('a catalog file that cannot be parsed reports a load failure', () async {
    final file = await writeUndecodableCatalog();
    final catalog = HygStarCatalog(catalogPath: file.path);

    final stars = await catalog.loadObjects();

    expect(
      catalog.loadOutcome,
      StarCatalogLoadOutcome.parseFailed,
      reason: 'the load did not succeed, so it must not claim it did',
    );
    expect(
      catalog.isUsingFallback,
      isTrue,
      reason: 'the sky on screen is the built-in list; the UI must be told',
    );
    expect(
      stars,
      isNotEmpty,
      reason: 'a failed parse must not render as an empty sky',
    );
  });

  test('a failed parse is cached, not retried on every load', () async {
    final file = await writeUndecodableCatalog();
    final catalog = HygStarCatalog(catalogPath: file.path);

    final first = await catalog.loadObjects();
    // Replacing the file with a valid-but-empty catalog proves the second call
    // never re-read it: a re-parse would now succeed and return no stars.
    await file.writeAsString('id,hip,hd\n');
    final second = await catalog.loadObjects();

    expect(identical(first, second), isTrue);
    expect(catalog.loadOutcome, StarCatalogLoadOutcome.parseFailed);
  });

  test(
    'a missing catalog file is reported as missing, not as a failure',
    () async {
      final catalog = HygStarCatalog(catalogPath: '${tempDir.path}/absent.csv');

      final stars = await catalog.loadObjects();

      expect(catalog.loadOutcome, StarCatalogLoadOutcome.fileMissing);
      expect(catalog.isUsingFallback, isTrue);
      expect(stars, isNotEmpty);
    },
  );

  test('a catalog that parses is reported as loaded', () async {
    final file = File('${tempDir.path}/hygdata.csv');
    // Header plus one well-formed HYG v3 row (30+ columns).
    final row = List<String>.filled(33, '');
    row[0] = '1';
    row[6] = 'Test Star';
    row[7] = '5.5'; // ra hours
    row[8] = '-5.4'; // dec degrees
    row[13] = '2.5'; // magnitude
    row[15] = 'G2V';
    row[29] = 'ORI';
    await file.writeAsString(
      '${List<String>.filled(33, 'c').join(',')}\n'
      '${row.join(',')}\n',
    );

    final catalog = HygStarCatalog(catalogPath: file.path);
    final stars = await catalog.loadObjects();

    expect(catalog.loadOutcome, StarCatalogLoadOutcome.loaded);
    expect(catalog.isUsingFallback, isFalse);
    expect(stars, hasLength(1));
  });
}
