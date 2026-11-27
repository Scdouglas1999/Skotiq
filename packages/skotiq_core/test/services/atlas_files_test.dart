import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/src/services/sky_atlas/atlas_files.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('atlas_files_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a legacy-named sidecar is found when the current one is absent', () {
    expect(existingAtlasSidecarPath(dir.path, '7'), p.join(dir.path, '7.skt'));
    File(p.join(dir.path, '7.nst')).writeAsStringSync('x');
    expect(existingAtlasSidecarPath(dir.path, '7'), p.join(dir.path, '7.nst'));
    File(p.join(dir.path, '7.skt')).writeAsStringSync('x');
    expect(existingAtlasSidecarPath(dir.path, '7'), p.join(dir.path, '7.skt'));
    expect(isAtlasSidecar('a/B.NST'), isTrue);
    expect(isAtlasSidecar('a/b.fits'), isFalse);
  });

  test(
    'eviction drops aged files, then the oldest until the rest fit',
    () async {
      final now = DateTime(2026, 11, 27);
      EvictionCandidate at(String name, int daysAgo, int size) => (
        file: File(p.join(dir.path, name)),
        modified: now.subtract(Duration(days: daysAgo)),
        size: size,
      );
      final removed = <String>[];
      final result = await evictAgedThenOldest(
        [
          at('aged', 20, 5),
          at('old', 9, 10),
          at('mid', 5, 10),
          at('new', 1, 10),
        ],
        cutoff: now.subtract(const Duration(days: 14)),
        maxBytes: 15,
        delete: (file) async {
          removed.add(p.basename(file.path));
          return true;
        },
      );
      expect(removed, ['aged', 'old', 'mid']);
      expect(result, (deleted: 3, reclaimedBytes: 25));
    },
  );

  test(
    'a file that cannot be removed still counts toward the budget',
    () async {
      final now = DateTime(2026, 11, 27);
      final result = await evictAgedThenOldest(
        [
          (file: File('a'), modified: now, size: 10),
          (file: File('b'), modified: now, size: 10),
        ],
        cutoff: now.subtract(const Duration(days: 1)),
        maxBytes: 5,
        delete: (file) async => file.path == 'b',
      );
      expect(result, (deleted: 1, reclaimedBytes: 10));
    },
  );
}
