import 'package:skotiq_core/database.dart';

/// Claim this process's database before native stores or device watchers start.
///
/// The lock stays in [SingleInstanceLock]'s process table until exit. Dropping
/// it here would free the database before the window exists. The database
/// opener acquires again and shares this claim. [SkotiqAlreadyRunningException]
/// exits 75 (EX_TEMPFAIL). `SKOTIQ_ALLOW_MULTIPLE_INSTANCES` still skips the
/// claim, inside [SingleInstanceLock.acquire].
Future<void> claimDesktopInstance() async {
  await SingleInstanceLock.claimOrExit(await resolveDefaultDatabaseFile());
}
