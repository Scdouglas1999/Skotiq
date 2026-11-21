import 'dart:io';

import '../../../../packages/skotiq_core/lib/src/database/single_instance_lock.dart';

/// Process entry for the single-instance claim. Holds the lock until stdin
/// closes, or exits 75 when another process already holds it. Does not open
/// SQLite.
Future<void> main(List<String> args) async {
  final database = File(args.single);
  await SingleInstanceLock.claimOrExit(database);
  stdout.writeln('held');
  await stdout.flush();
  await stdin.first;
}
