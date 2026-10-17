import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';

/// Give a [ProviderContainer] its own private, in-memory database.
///
/// Why this is not optional for any test that builds more than one container:
/// the unoverridden [databaseProvider] constructs a fresh [SkotiqDatabase]
/// per container, and every one of them resolves the SAME on-disk file (the
/// per-isolate temp dir stubbed into `path_provider` by
/// `test/flutter_test_config.dart`). Two containers alive at once therefore
/// point two SQLite writers at one file and BOTH run schema creation. Whichever
/// loses the race fails with `database is locked` or
/// `index idx_profiles_name already exists`, surfacing as an unrelated-looking
/// failure in whatever the test was actually doing — e.g. a capture test
/// reporting that the frame "could not be saved".
///
/// It only bites when the two opens overlap, which is why it read as
/// "cold-start flakiness": it needs a loaded machine (a full-suite run) to
/// reproduce and passes every time the file is run on its own.
///
/// `NativeDatabase.memory()` gives each container a database no other container
/// can see, which is both faster and the isolation these tests assume they have.
Override inMemoryDatabaseOverride() {
  return databaseProvider.overrideWith((ref) {
    final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    ref.onDispose(database.close);
    return database;
  });
}
