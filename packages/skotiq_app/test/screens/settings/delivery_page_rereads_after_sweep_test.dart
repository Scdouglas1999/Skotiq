// Settings > Delivery, left open, must not go on stating a failure the app's
// own retry sweep has already fixed.
//
// What was measured against the release bundle, with the embedded server armed
// so DeliveryRetrySweeper ran in-process (the normal rig configuration): the
// page read "destinationUnreachable: <path> is not on the filesystem right now
// — will retry (1 file owed)" at 04:00:34, the directory was created at
// 04:00:45, the sweep delivered the row at 04:01:04 and the file appeared on
// disk at 04:01:05 — and the still-open page read the SAME sentence at 04:01:58
// and again at 04:02:28 after clicking away to another settings section and
// back. Only a restart re-read the journal, because the settings shell keeps
// the section mounted so `autoDispose` never fires on navigation either.
//
// This test is shaped like that run: a real journal, a real destination
// directory on the filesystem that starts absent and is created mid-test, the
// real DeliveryRetrySweeper over the real transport factory writing real bytes,
// and the page never unmounted between the two reads.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/delivery_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show PairedDevice;

import '../../harness/harness.dart';

/// Drops "overflowed" layout exceptions for the current test; the delivery rows
/// are multi-line and a long status sentence can spill a few pixels at the test
/// surface size.
void _swallowKnownOverflows() {
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    defaultOnError?.call(details);
  };
  addTearDown(() {
    FlutterError.onError = defaultOnError;
  });
}

/// Whether any sentence the page is rendering right now carries [fragment].
bool _pageSays(WidgetTester tester, String fragment) => tester
    .widgetList<Text>(find.byType(Text))
    .any((text) => (text.data ?? '').contains(fragment));

/// One destination row already owed a file, on a watched folder that is not
/// there. Returns the target id.
///
/// [content] is a parameter because a destination whose selection is EMPTY is
/// still owed the rows it collected before the selection was cleared — the
/// case the page and the sweep have to agree about.
Future<int> _seedOwedRow(
  SkotiqDatabase database, {
  required Directory drop,
  required File master,
  String name = 'attic-nas',
  Set<ArtifactContent> content = const {ArtifactContent.linearMasters},
}) async {
  final targetId = await DeliveryTargetsDao(database).create(
    name: name,
    kind: ArtifactDestinationKind.watchedFolder,
    configJson: '{"path":"${drop.path}"}',
    content: content,
  );
  final journal = DeliveryJournalDao(database);
  final jobId = await DarkroomJobsDao(database).enqueue();
  await journal.recordAttempt(
    targetId: targetId,
    jobId: jobId,
    filePath: master.path,
    bytes: master.lengthSync(),
  );
  // Dated well into the past so the row is due the instant a sweep looks: the
  // ladder runs off `updated_at`, not off wall-clock since startup.
  await journal.markRetrying(
    targetId: targetId,
    jobId: jobId,
    filePath: master.path,
    error:
        'destinationUnreachable: ${drop.path} is not on the filesystem right '
        'now',
    now: DateTime.utc(2026),
  );
  return targetId;
}

List<Override> _overrides() => [
      secretsStoreProvider.overrideWithValue(
        SecretsStore(InMemorySecureKeyValueStore()),
      ),
      pairedDesktopReaderProvider.overrideWithValue(
        () async => const <PairedDevice>[],
      ),
      // The real filesystem answers this one — the whole point is that the
      // blocker the page reports stops being true partway through. Asked
      // synchronously: a widget test's clock is fake, so an async `exists()`
      // would leave `pumpAndSettle` returning on the loading state.
      watchedFolderExistsProvider.overrideWithValue(
        (path) async => Directory(path).existsSync(),
      ),
    ];

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('sk-delivery-reread');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets(
    'a healed destination turns the open page green without navigation',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);

      // The destination directory does NOT exist yet. Delivery never creates
      // one, which is exactly the blocker the page reports.
      final drop = Directory('${root.path}${Platform.pathSeparator}drop');
      final master = File('${root.path}${Platform.pathSeparator}L.fits')
        ..writeAsBytesSync(List<int>.filled(4096, 7));
      await _seedOwedRow(database, drop: drop, master: master);

      final handle = await pumpAppScreen(
        tester,
        const DeliverySettings(),
        database: database,
        size: const Size(1280, 1400),
        extraOverrides: _overrides(),
      );

      expect(
        _pageSays(tester, 'will retry'),
        isTrue,
        reason: 'the seeded row is owed and the directory is not there',
      );
      expect(_pageSays(tester, 'is not on the filesystem right now'), isTrue);

      // The operator mounts the share. Nothing is touched in the app.
      drop.createSync();

      // The overnight sweep runs on its own timer, in this same process. Drive
      // one pass directly rather than waiting out the 30-second due check;
      // `runAsync` because it moves real bytes through a real transport.
      final report = await tester.runAsync(
        () => handle.container.read(deliveryRetrySweeperProvider).sweepOnce(),
      );
      expect(report?.delivered, 1, reason: 'the row was due and deliverable');
      expect(
        drop.listSync().whereType<File>(),
        isNotEmpty,
        reason: 'the sweep really moved the bytes',
      );

      // No navigation, no rebuild of the section, no restart.
      await tester.pumpAndSettle();

      expect(
        _pageSays(tester, 'will retry'),
        isFalse,
        reason:
            'the journal no longer holds a failure, so the page must not hold '
            'one either',
      );
      expect(
        _pageSays(tester, 'is not on the filesystem right now'),
        isFalse,
        reason: 'the directory is there now and the page re-asked',
      );
      expect(_pageSays(tester, 'Delivered'), isTrue);
    },
  );

  testWidgets(
    'a pass that changed nothing leaves the page reading the same thing',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);

      final drop = Directory('${root.path}${Platform.pathSeparator}drop');
      final master = File('${root.path}${Platform.pathSeparator}L.fits')
        ..writeAsBytesSync(List<int>.filled(4096, 7));
      await _seedOwedRow(database, drop: drop, master: master);

      final handle = await pumpAppScreen(
        tester,
        const DeliverySettings(),
        database: database,
        size: const Size(1280, 1400),
        extraOverrides: _overrides(),
      );

      expect(_pageSays(tester, 'will retry'), isTrue);

      // The share is still down, so the pass re-attempts and fails again. The
      // page re-reads and states the same fact — a re-read must never invent
      // progress out of the bare fact that a sweep ran.
      await tester.runAsync(
        () => handle.container.read(deliveryRetrySweeperProvider).sweepOnce(),
      );
      await tester.pumpAndSettle();

      expect(_pageSays(tester, 'will retry'), isTrue);
      expect(_pageSays(tester, 'Delivered'), isFalse);
    },
  );

  testWidgets(
    'a peer file the RIG lost stops being reported as the desktop\'s to pull',
    (tester) async {
      // Measured against the release bundle on one launch: the manifest
      // endpoint answered `sourceMissing` for a published draft deleted from
      // the rig, the sweep on that same launch logged `peer-desktop: 4
      // awaiting pull`, and the settings row read "Published 4 files, 671.6 KB
      // — waiting for office-pc to pull" — 338 KB of which was the file the
      // rig no longer had. The peer arm counted rows without reading the disk,
      // so the row never failed and the operator had no control on it either.
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);

      final draft = File('${root.path}${Platform.pathSeparator}draft.jpg')
        ..writeAsBytesSync(List<int>.filled(4096, 3));
      final targetId = await DeliveryTargetsDao(database).create(
        name: 'peer-desktop',
        kind: ArtifactDestinationKind.peer,
        configJson: '{"peerId":"office-pc"}',
        content: {ArtifactContent.draftRender},
      );
      final jobId = await DarkroomJobsDao(database).enqueue();
      // Publication is the journal row and nothing else: `retrying` with no
      // error is exactly what a published, unpulled file looks like.
      await DeliveryJournalDao(database).recordAttempt(
        targetId: targetId,
        jobId: jobId,
        filePath: draft.path,
        bytes: draft.lengthSync(),
      );

      final handle = await pumpAppScreen(
        tester,
        const DeliverySettings(),
        database: database,
        size: const Size(1280, 1400),
        extraOverrides: _overrides(),
      );

      expect(
        _pageSays(tester, 'waiting for office-pc to pull'),
        isTrue,
        reason: 'while the file is on the rig, the desktop is who it waits on',
      );

      // The file leaves the rig before the desktop ever collects it.
      draft.deleteSync();

      final report = await tester.runAsync(
        () => handle.container.read(deliveryRetrySweeperProvider).sweepOnce(),
      );
      expect(report?.awaitingPull, 0);
      expect(report?.failed, 1);

      await tester.pumpAndSettle();

      expect(
        _pageSays(tester, 'waiting for office-pc to pull'),
        isFalse,
        reason: 'the rig lost the file; that is not the desktop\'s debt',
      );
      expect(_pageSays(tester, 'sourceMissing'), isTrue);
      expect(
        _pageSays(tester, 'never pulled it'),
        isTrue,
        reason: 'the sentence says which side the file left from',
      );
    },
  );

  testWidgets(
    'an empty selection and the sweep state the same thing on one launch',
    (tester) async {
      // Measured against the release bundle on one launch: the sweep logged
      // `empty-selection: 1 delivered` and wrote the file into the folder,
      // while the row's status line LED with "Nothing selected — this
      // destination receives no files." The selection picks destinations at
      // job time only; rows already owed are on the sweep's work list and go.
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);

      // The folder is there from the start — nothing structural is in the way,
      // so the only claim under test is the one about the selection.
      final drop = Directory('${root.path}${Platform.pathSeparator}drop')
        ..createSync();
      final master = File('${root.path}${Platform.pathSeparator}L.fits')
        ..writeAsBytesSync(List<int>.filled(4096, 7));
      await _seedOwedRow(
        database,
        drop: drop,
        master: master,
        name: 'empty-selection',
        content: const {},
      );

      final handle = await pumpAppScreen(
        tester,
        const DeliverySettings(),
        database: database,
        size: const Size(1280, 1400),
        extraOverrides: _overrides(),
      );

      expect(
        _pageSays(tester, 'this destination receives no files'),
        isFalse,
        reason: 'a file is owed here and the sweep is about to deliver it',
      );
      expect(_pageSays(tester, 'receives no new files'), isTrue);
      expect(
        _pageSays(tester, '1 file owed from before is still delivered'),
        isTrue,
      );

      final report = await tester.runAsync(
        () => handle.container.read(deliveryRetrySweeperProvider).sweepOnce(),
      );
      expect(
        report?.delivered,
        1,
        reason: 'the sweep works from the journal, not from the selection',
      );
      expect(drop.listSync().whereType<File>(), isNotEmpty);

      await tester.pumpAndSettle();

      expect(
        _pageSays(tester, 'this destination receives no files'),
        isFalse,
        reason: 'the file is in the folder the page would be talking about',
      );
      expect(_pageSays(tester, 'receives no new files'), isTrue);
      expect(_pageSays(tester, 'Delivered'), isTrue);
    },
  );
}
