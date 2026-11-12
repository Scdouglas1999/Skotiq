import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/integrity_findings.dart';

void main() {
  test('a single ok row is a healthy database', () {
    final findings = classifyIntegrityCheck(['ok']);
    expect(findings.healthy, isTrue);
    expect(findings.indexOnly, isFalse);
    expect(findings.messages, isEmpty);
  });

  // One case per index message SQLite 3.53 `src/pragma.c` writes, as the
  // bundled library prints it.
  const indexMessages = {
    'wrong # of entries in index idx_images_session': 'idx_images_session',
    'row 812 missing from index idx_images_session': 'idx_images_session',
    'rowid not at end-of-record for row 812 of index idx_images_target':
        'idx_images_target',
    'row 812 values differ from index idx_targets_name_nocase':
        'idx_targets_name_nocase',
    'non-unique entry in index sqlite_autoindex_targets_1':
        'sqlite_autoindex_targets_1',
    'index idx_tiles_value stores an imprecise floating-point value for row '
            '77':
        'idx_tiles_value',
  };
  for (final MapEntry(key: message, value: index) in indexMessages.entries) {
    test('"$message" is an index problem naming $index', () {
      final findings = classifyIntegrityCheck([message]);
      expect(findings.indexOnly, isTrue);
      expect(findings.indexes, {index});
      expect(findings.messages, [message]);
    });
  }

  test('an index name with spaces is read whole', () {
    final findings = classifyIntegrityCheck([
      'row 3 missing from index my odd index',
    ]);
    expect(findings.indexes, {'my odd index'});
  });

  // Everything else SQLite reports is damage to the data or its pages.
  const damageMessages = [
    // The b-tree checks, one row with a header line.
    '*** in database main ***\nTree 5 page 1234 cell 3: Rowid 77 out of order',
    '*** in database main ***\n2nd reference to page 5\nPage 3: never used',
    '*** in database main ***\nFreelist: size is 4 but should be 5',
    '*** in database main ***\nMultiple uses for byte 1200 of page 7',
    '*** in database main ***\nFragmentation of 12 bytes reported as 0 on '
        'page 9',
    '*** in database main ***\nTree 2 page 2: btreeInitPage() returns error '
        'code 11',
    '*** in database main ***\nmax rootpage (40) disagrees with header (41)',
    // Row and constraint checks.
    'row not in PRIMARY KEY order for settings',
    'NULL value in captured_images.file_path',
    'non-INTEGER value in sessions.id',
    'NUMERIC value in targets.name',
    'TEXT value in targets.ra',
    'CHECK constraint failed in captured_images',
    // A check that SQLite stopped with an error.
    'database disk image is malformed',
  ];
  for (final message in damageMessages) {
    test('"${message.replaceAll('\n', r'\n')}" is damage', () {
      final findings = classifyIntegrityCheck([message]);
      expect(findings.healthy, isFalse);
      expect(findings.indexOnly, isFalse);
      expect(findings.messages, isNot(contains(startsWith('***'))));
    });
  }

  test('the b-tree row is split into one message per line', () {
    final findings = classifyIntegrityCheck([
      '*** in database main ***\n2nd reference to page 5\nPage 3: never used',
      'wrong # of entries in index i',
    ]);
    expect(findings.messages, [
      '2nd reference to page 5',
      'Page 3: never used',
      'wrong # of entries in index i',
    ]);
  });

  test('index problems next to damage are not index-only', () {
    final findings = classifyIntegrityCheck([
      'row 1 missing from index i',
      'NULL value in t.a',
    ]);
    expect(findings.indexOnly, isFalse);
    expect(findings.indexes, {'i'});
  });

  test('several indexes are all named', () {
    final findings = classifyIntegrityCheck([
      'row 1 missing from index a',
      'row 2 missing from index a',
      'wrong # of entries in index b',
    ]);
    expect(findings.indexOnly, isTrue);
    expect(findings.indexes, {'a', 'b'});
  });
}
