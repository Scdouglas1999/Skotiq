import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/tutorial_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [databaseProvider.overrideWithValue(database)],
  );

  test(
    'a synchronous read before the load completes sees nothing dismissed',
    () {
      // This is the trap, pinned deliberately: the initial state is an empty set
      // and the database read is asynchronous, so any caller deciding from a
      // synchronous first read concludes "not dismissed" no matter what is
      // persisted. `ready` exists so callers do not have to know that.
      final container = makeContainer();
      addTearDown(container.dispose);
      expect(container.read(dismissedTourPromptsProvider), isEmpty);
    },
  );

  test('a dismissal survives a fresh container once ready completes', () async {
    final first = makeContainer();
    await first.read(dismissedTourPromptsProvider.notifier).ready;
    await first
        .read(dismissedTourPromptsProvider.notifier)
        .dismissPrompt('dashboard');
    expect(first.read(dismissedTourPromptsProvider), contains('dashboard'));
    first.dispose();

    // A new container stands in for an app restart against the same database.
    final second = makeContainer();
    addTearDown(second.dispose);
    await second.read(dismissedTourPromptsProvider.notifier).ready;
    expect(
      second.read(dismissedTourPromptsProvider),
      contains('dashboard'),
      reason: 'a dismissed tour prompt must not come back after a restart',
    );
  });

  test('ready is idempotent and safe to await repeatedly', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(dismissedTourPromptsProvider.notifier);
    await Future.wait([notifier.ready, notifier.ready, notifier.ready]);
    expect(container.read(dismissedTourPromptsProvider), isEmpty);
  });

  test('only the dismissed screen is remembered', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final notifier = container.read(dismissedTourPromptsProvider.notifier);
    await notifier.ready;
    await notifier.dismissPrompt('dashboard');
    final state = container.read(dismissedTourPromptsProvider);
    expect(state, contains('dashboard'));
    expect(state, isNot(contains('imaging')));
  });
}
