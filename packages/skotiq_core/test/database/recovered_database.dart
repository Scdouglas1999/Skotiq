import 'package:drift/drift.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/database/recovery/crash_recovery.dart';

/// A database as a host process sees it: opened, then put through the
/// start-up recovery before the first query of the test returns.
///
/// The application calls [recoverFromPreviousProcessExit] from its start-up
/// steps. Drift opens lazily, so the tests attach it to the end of the open
/// instead of repeating the call after every construction.
class RecoveredDatabase extends SkotiqDatabase {
  RecoveredDatabase(super.e) : super.forTesting();

  @override
  MigrationStrategy get migration {
    final base = super.migration;
    return MigrationStrategy(
      onCreate: base.onCreate,
      onUpgrade: base.onUpgrade,
      beforeOpen: (details) async {
        await base.beforeOpen?.call(details);
        await recoverFromPreviousProcessExit(this);
      },
    );
  }
}
