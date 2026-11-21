import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('a second process exits 75 and does not touch the database', () async {
    final root = await Directory.systemTemp.createTemp('sk_claim_');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final database = File(p.join(root.path, 'skotiq.db'));
    final script =
        [
          'test/support/claim_second_instance.dart',
          'apps/desktop/test/support/claim_second_instance.dart',
        ].cast<String?>().firstWhere(
          (candidate) => candidate != null && File(candidate).existsSync(),
          orElse: () => null,
        );
    expect(
      script,
      isNotNull,
      reason: 'claim script not found from ${Directory.current.path}',
    );
    final claimScript = script!;
    final dart = await Process.run('which', ['dart']);
    expect(
      dart.exitCode,
      0,
      reason: 'dart is required to start a second process',
    );
    final executable = (dart.stdout as String).trim();

    final holder = await Process.start(executable, [
      claimScript,
      database.path,
    ]);
    addTearDown(() async {
      holder.kill();
      await holder.exitCode;
    });
    final held = await holder.stdout
        .transform(const SystemEncoding().decoder)
        .firstWhere((chunk) => chunk.contains('held'))
        .timeout(const Duration(seconds: 20));
    expect(held, contains('held'));
    expect(await database.exists(), isFalse);

    final second = await Process.run(executable, [claimScript, database.path]);
    expect(second.exitCode, 75);
    expect(await database.exists(), isFalse);
    final names = await root
        .list()
        .map((entity) => p.basename(entity.path))
        .toList();
    expect(names.where((name) => name.startsWith('skotiq-corrupt')), isEmpty);
  });
}
