// The words a restore is reported in are one rule: a linked client builds
// them from what the host sends and reads the same sentence the host's own
// window shows.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

void main() {
  test('a merge outcome reads the same on the host and over the wire', () {
    final result = RestoreResult(
      success: true,
      timestamp: DateTime(2026, 11, 15),
      itemsRestored: 189410,
      categoryCounts: const {'captured_images': 50},
      alreadyHere: 1491088,
      notRestored: const {'targets': 1, 'integrated_master_frames': 4},
      leftOut: const {
        RestoreLeftOut.yoursKept: 1,
        RestoreLeftOut.insideYours: 4,
      },
    );
    final wire =
        jsonDecode(jsonEncode(result.toWire())) as Map<String, dynamic>;

    expect(restoreReportFromWire(wire), result.report);
    expect(
      result.report,
      'Added 189410 rows from the backup. 1491088 rows were here already. '
      'Your settings were not changed. 5 backup rows were left out (targets '
      '1, integrated master frames 4): 1 because this database has its own '
      'version of the record, which was kept; 4 because they are part of a '
      'record this database already has, and a merge adds nothing inside '
      'your records. They are still in the backup file.',
    );
  });

  test('a merge that leaves nothing out says so in two sentences', () {
    final result = RestoreResult(
      success: true,
      timestamp: DateTime(2026, 11, 15),
      itemsRestored: 1,
    );
    expect(
      result.report,
      'Added 1 row from the backup. Your settings were not changed.',
    );
    expect(result.notRestoredNotice, isNull);
  });

  test('a staged replace says when it takes effect and where the old '
      'database is saved', () {
    final result = RestoreResult(
      success: true,
      timestamp: DateTime(2026, 11, 15),
      mode: RestoreMode.replace,
      itemsRestored: 1680755,
      pendingRestart: true,
      safetyBackupPath: '/backups/skotiq-backup-before-replace-x.skbackup',
    );
    final wire =
        jsonDecode(jsonEncode(result.toWire())) as Map<String, dynamic>;
    expect(wire['pendingRestart'], isTrue);
    expect(restoreReportFromWire(wire), result.report);
    expect(result.report, contains('when Skotiq next starts'));
    expect(
      result.report,
      contains('saved as skotiq-backup-before-replace-x.skbackup'),
    );
  });

  test('what each way of restoring does is said before it is chosen', () {
    expect(RestoreMode.merge.summary, contains('your settings stay'));
    expect(RestoreMode.merge.summary, contains('Nothing you have is changed'));
    expect(RestoreMode.replace.summary, contains('safety backup'));
    expect(RestoreMode.replace.summary, contains('replace everything here'));
    expect(RestoreMode.fromWire('replace'), RestoreMode.replace);
    expect(RestoreMode.fromWire(null), RestoreMode.merge);
  });
}
