import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/backup_list_entry.dart';

void main() {
  test('remote backup rows without a stable id are dropped', () {
    final entries = parseRemoteBackupList([
      {
        'id': 'good-id',
        'fileName': 'skotiq.skbackup',
        'createdAt': 123,
        'fileSize': 456,
      },
      {'id': '', 'fileName': 'empty-id.skbackup'},
      {'id': 7, 'fileName': 'wrong-id-type.skbackup'},
    ]);

    expect(entries, hasLength(1));
    expect(entries.single.id, 'good-id');
    expect(entries.single.fileSize, 456);
  });
}
