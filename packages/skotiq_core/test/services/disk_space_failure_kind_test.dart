import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/disk_space_service.dart';

/// Observed on the desktop dashboard 2026-08-10: the Readiness panel read
/// "Disk query failed" for a capture folder that simply was not on this
/// machine. The service knew exactly that — it had already thrown
/// "Path does not exist; cannot query free space" with the path attached —
/// but the card rendered one constant string for every possible cause.
///
/// The distinction matters on a rig left running overnight: an unmounted
/// drive is something the operator can fix, and "disk query failed" is not.
void main() {
  late DiskSpaceService service;

  setUp(() => service = DiskSpaceService());

  test('an unconfigured capture path is its own kind', () async {
    await expectLater(
      service.query(''),
      throwsA(
        isA<DiskSpaceException>().having(
          (e) => e.kind,
          'kind',
          DiskSpaceFailureKind.pathNotConfigured,
        ),
      ),
    );
  });

  test('a configured folder that is not on disk reports pathMissing', () async {
    // The real shape of the incident: a path saved on one machine, opened on
    // another. Nothing about it is a query failure.
    final missing = '${Directory.systemTemp.path}/ns-not-here-4f2a9c';
    expect(Directory(missing).existsSync(), isFalse);

    await expectLater(
      service.query(missing),
      throwsA(
        isA<DiskSpaceException>()
            .having((e) => e.kind, 'kind', DiskSpaceFailureKind.pathMissing)
            .having((e) => e.path, 'path', missing),
      ),
    );
  });

  test('a real directory answers with usable numbers', () async {
    final dir = Directory.systemTemp.createTempSync('ns-disk-ok');
    addTearDown(() => dir.deleteSync(recursive: true));

    final info = await service.query(dir.path);

    expect(info.totalBytes, greaterThan(0));
    expect(info.freeBytes, greaterThanOrEqualTo(0));
    expect(info.freeBytes, lessThanOrEqualTo(info.totalBytes));
  });

  test('queryFailed stays the default so unclassified causes are not '
      'mislabelled as a missing folder', () {
    const e = DiskSpaceException('/somewhere', 'subprocess exited 1');
    expect(e.kind, DiskSpaceFailureKind.queryFailed);
  });
}
