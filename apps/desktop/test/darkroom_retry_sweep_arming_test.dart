// Who arms the Darkroom delivery retry sweep.
//
// The sweep used to be armed inside HeadlessApiServer's start, which a desktop
// GUI only reaches when `web_server_enabled` is on — and that is off on a fresh
// install (`AppSettings @Default(false) webServerEnabled`). Measured against the
// release bundle at 08:49 UTC: a GUI with remote access off ran its startup
// catch-up pass, failed it with `destinationUnreachable` (attempts 1, next
// attempt due at 08:50:10), had its destination directory created at 08:49:38 —
// and at 08:53:39 the journal row was still `retrying` with `updated_at`
// unchanged and the drop directory empty. The same database with
// `web_server_enabled=true` delivered the same row inside 30 seconds. Meanwhile
// a pass stopped during delivery tells the operator, in as many words, that
// "the retry sweep resumes them".
//
// So the sweep belongs to delivery: `resumeDarkroomWork` is the one seam every
// mode that owns the journal runs, and it is what arms the timer.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/desktop_app_bootstrap.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;
  late ProviderContainer container;

  /// The overrides every case shares: the in-memory database and a keyring
  /// that answers without a platform secret service.
  List<Override> baseOverrides() => [
    databaseProvider.overrideWithValue(database),
    secretsStoreProvider.overrideWithValue(
      SecretsStore(InMemorySecureKeyValueStore()),
    ),
  ];

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: baseOverrides());
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test('resumeDarkroomWork arms the periodic sweep', () async {
    final sweeper = container.read(deliveryRetrySweeperProvider);
    expect(
      sweeper.isRunning,
      isFalse,
      reason: 'reading the provider must not arm anything by itself',
    );

    resumeDarkroomWork(
      container: container,
      logger: container.read(loggingServiceProvider),
      logSource: 'test',
    );

    expect(
      sweeper.isRunning,
      isTrue,
      reason:
          'a rig that owns this journal owes it a sweep whether or not remote '
          'access is switched on',
    );
  });

  test('the sweep is armed before the catch-up pass is awaited', () {
    // The catch-up drains the dawn queue and then sweeps once, both of which
    // are network-bound and can sit for minutes on a host that is still
    // asleep. The ladder for every other row must not wait behind that.
    resumeDarkroomWork(
      container: container,
      logger: container.read(loggingServiceProvider),
      logSource: 'test',
    );

    // Synchronously true: no `await` has been given up yet.
    expect(container.read(deliveryRetrySweeperProvider).isRunning, isTrue);
  });

  test('arming twice keeps one timer', () async {
    // The headless daemon runs this seam AND starts the API server; the GUI
    // runs it once. Neither may end up with two passes over one journal.
    final sweeper = container.read(deliveryRetrySweeperProvider);
    final logger = container.read(loggingServiceProvider);

    resumeDarkroomWork(container: container, logger: logger, logSource: 'test');
    resumeDarkroomWork(container: container, logger: logger, logSource: 'test');

    expect(sweeper.isRunning, isTrue);
    expect(
      container.read(deliveryRetrySweeperProvider),
      same(sweeper),
      reason: 'one provider instance, so `start()`\'s own idempotence holds',
    );
  });

  test(
    'the armed sweep delivers a healed destination with nobody watching',
    () async {
      // The whole chain the live run broke, end to end: the bootstrap arms the
      // timer, the timer's due check reads the journal, the sweep opens the real
      // watched-folder transport and the bytes land — with no operator action and
      // no remote-access server anywhere in the process. The cadences are shrunk
      // so the test drives the ladder instead of waiting out 30 seconds of it.
      final root = Directory.systemTemp.createTempSync('sk-arming');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final drop = Directory('${root.path}${Platform.pathSeparator}drop');
      final master = File('${root.path}${Platform.pathSeparator}L.fits')
        ..writeAsBytesSync(List<int>.filled(2048, 3));

      container.dispose();
      container = ProviderContainer(
        overrides: [
          ...baseOverrides(),
          // The production ladder is 1 m / 3 m / 9 m off `updated_at`; this one
          // is the same shape at 10 ms so the case drives every rung instead of
          // waiting one out. Everything else — the DAOs, the transport factory,
          // the real watched-folder transport — is the production assembly.
          deliveryServiceProvider.overrideWith(
            (ref) => DeliveryService(
              targets: DeliveryTargetsDao(database),
              journal: DeliveryJournalDao(database),
              transportFactory: ref.watch(artifactTransportFactoryProvider),
              logger: ref.watch(loggingServiceProvider),
              policy: const DeliveryRetryPolicy(
                firstBackoff: Duration(milliseconds: 10),
                multiplier: 1,
              ),
            ),
          ),
          deliveryRetrySweeperProvider.overrideWith(
            (ref) => DeliveryRetrySweeper(
              delivery: ref.watch(deliveryServiceProvider),
              logger: ref.watch(loggingServiceProvider),
              interval: const Duration(hours: 1),
              dueCheckInterval: const Duration(milliseconds: 20),
            ),
          ),
        ],
      );

      final targetId = await DeliveryTargetsDao(database).create(
        name: 'attic-nas',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"${drop.path}"}',
        content: {ArtifactContent.linearMasters},
      );
      final journal = DeliveryJournalDao(database);
      final jobId = await DarkroomJobsDao(database).enqueue();
      await journal.recordAttempt(
        targetId: targetId,
        jobId: jobId,
        filePath: master.path,
        bytes: 2048,
      );
      await journal.markRetrying(
        targetId: targetId,
        jobId: jobId,
        filePath: master.path,
        error:
            'destinationUnreachable: ${drop.path} is not on the filesystem '
            'right now',
        now: DateTime.utc(2026),
      );

      resumeDarkroomWork(
        container: container,
        logger: container.read(loggingServiceProvider),
        logSource: 'test',
      );

      // Wait for the startup catch-up pass to run and FAIL against the absent
      // directory before healing it. Otherwise the catch-up would be the thing
      // that delivered, and this case would pass with no timer armed at all —
      // which is exactly the state the release bundle was in.
      final failedBy = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(failedBy)) {
        final row = (await journal.listForTarget(targetId)).single;
        if (row.attempts > 1) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(
        (await journal.listForTarget(targetId)).single.attempts,
        greaterThan(1),
        reason:
            'the catch-up pass has spent its attempt on the absent directory',
      );

      // The operator mounts the share, some time after that failure.
      drop.createSync();

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline) &&
          drop.listSync().whereType<File>().isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(
        drop.listSync().whereType<File>(),
        isNotEmpty,
        reason: 'the periodic sweep is what picks the row up once it is due',
      );
      final row = (await journal.listForTarget(targetId)).single;
      expect(row.state, DeliveryAttemptState.delivered);
    },
  );
}
