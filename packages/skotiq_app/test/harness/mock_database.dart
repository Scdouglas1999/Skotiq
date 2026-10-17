// In-memory drift database factory for skotiq_app widget tests.
//
// Why this lives in skotiq_app/test/harness/ rather than reusing the
// existing helper at packages/skotiq_core/test/mocks/mock_database.dart:
// files under `test/` are not exportable across packages (Dart's test-layout
// convention). The package boundary forces this duplication — keep both
// helpers thin and behaviourally identical so tests work the same on either
// side of the boundary.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';

/// Build a fresh in-memory `SkotiqDatabase` for a single widget test.
///
/// Every call returns a new isolated database — tests should call
/// `db.close()` in a `tearDown` (or use `addTearDown(db.close)` inside the
/// test) so the underlying sqlite handle is released before the next test
/// runs. `NativeDatabase.memory()` opens an in-process sqlite file with no
/// disk footprint, so parallel tests cannot interfere.
///
/// Why not pre-populate seed data here: tests have widely varying setup
/// requirements (some need an active profile, some need empty state, some
/// need a queued sequence). Seeding belongs in the test body, not the
/// harness, so the harness stays generic.
SkotiqDatabase mockDatabase() {
  return SkotiqDatabase.forTesting(NativeDatabase.memory());
}

/// Give a [ProviderContainer] / [ProviderScope] its own private in-memory DB.
///
/// Same hazard as skotiq_core: the unoverridden [databaseProvider]
/// constructs a fresh [SkotiqDatabase] per container, and every one of
/// them resolves the SAME on-disk temp file. Two live containers therefore
/// race schema creation (`database is locked` / `index already exists`),
/// which shows up as flaky failures in unrelated assertions. Prefer this
/// over calling [mockDatabase] by hand whenever a test builds a
/// ProviderScope/ProviderContainer that is not going through [pumpAppScreen]
/// (which already wires an in-memory DB).
Override inMemoryDatabaseOverride() {
  return databaseProvider.overrideWith((ref) {
    // Deliberately not closed in ref.onDispose. Drift's StreamQueryStore
    // schedules a zero-duration Timer inside markAsClosed during database
    // close; when a ProviderScope is torn down at the end of a widget test
    // that timer is still pending and Flutter's binding fails the test with
    // `!timersPending`. Each call still gets a private NativeDatabase.memory()
    // handle, so containers cannot race on a shared file — the hazard this
    // helper exists to close. Handles are reclaimed when the isolate exits;
    // tests that need an explicit close should take mockDatabase() and pass
    // it through databaseProvider.overrideWithValue instead (see pumpAppScreen).
    return SkotiqDatabase.forTesting(NativeDatabase.memory());
  });
}
