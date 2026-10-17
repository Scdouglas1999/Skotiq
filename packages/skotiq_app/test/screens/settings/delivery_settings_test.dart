// Widget tests for the Delivery settings section (Darkroom Phase B, W4).
//
// What these lock in:
//
//   1. crud_round_trip — Add watched folder writes a real v58
//      `delivery_targets` row (kind, config_json path, content_json selection,
//      enabled), the list then renders it, editing renames it, and Delete
//      removes it. The assertions read the DATABASE, not the widget tree, so a
//      dialog that looks like it saved but writes nothing fails here.
//   2. masked_secret_never_rendered — an SFTP destination whose key is in the
//      keyring shows the masked placeholder and NEVER the key, in the list row
//      and in the editor. This is the one leak that cannot be un-shipped.
//   3. journal_states — every status sentence is derived from a
//      `delivery_journal` row: delivered / will-retry / failed / awaiting a
//      peer pull, plus the three honest not-delivering states (never run,
//      nothing selected, off). A configured-but-never-run destination must not
//      read as one that has delivered — the mock-push lesson.
//   4. a11y_semantics — the per-destination switch and edit control publish
//      names that say WHICH destination they act on.
//
// The database is the real in-memory `SkotiqDatabase` from the harness, so
// the DAOs, the raw-DDL v58 tables and their CHECK constraints are all
// exercised. The keyring is the in-memory `SecretsStore` double; the pairing
// database is replaced by the `pairedDesktopReaderProvider` seam so no test
// opens the on-disk pairing store.

import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/delivery_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show PairedDevice;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// Drops "overflowed" layout exceptions for the current test; re-forwards the
/// rest to the default presenter. The delivery rows are multi-line and a long
/// status sentence can spill a few pixels at the test surface size.
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

List<Override> _overrides({
  SecretsStore? secrets,
  List<PairedDevice> pairedDevices = const <PairedDevice>[],
  DeliverySweepRequest? sweep,
  WatchedFolderExists? folderExists,
}) {
  return [
    secretsStoreProvider.overrideWithValue(
      secrets ?? SecretsStore(InMemorySecureKeyValueStore()),
    ),
    pairedDesktopReaderProvider.overrideWithValue(() async => pairedDevices),
    // The real seam builds the transports, which would reach for a filesystem
    // and an SSH host from inside a widget test. What is under test here is
    // the journal the action writes, so the sweep it then asks for is a
    // double that records the ask.
    deliverySweepRequestProvider.overrideWithValue(
      sweep ?? () async => null,
    ),
    // The folder check is stated rather than performed. `/mnt/nas/...` is not
    // mounted on a CI runner, so the real `stat` would make every row in this
    // file report a missing directory — and reaching the machine's filesystem
    // from a widget test is also what made these tests race the provider: the
    // page renders its loading state, `pumpAndSettle` sees no scheduled frame
    // and returns before the I/O lands.
    watchedFolderExistsProvider.overrideWithValue(
      folderExists ?? (_) async => true,
    ),
  ];
}

Future<HarnessHandle> _pumpDelivery(
  WidgetTester tester,
  SkotiqDatabase database, {
  SecretsStore? secrets,
  List<PairedDevice> pairedDevices = const <PairedDevice>[],
  DeliverySweepRequest? sweep,
  WatchedFolderExists? folderExists,
}) {
  return pumpAppScreen(
    tester,
    const DeliverySettings(),
    database: database,
    size: const Size(1280, 1400),
    extraOverrides: _overrides(
      secrets: secrets,
      pairedDevices: pairedDevices,
      sweep: sweep,
      folderExists: folderExists,
    ),
  );
}

Finder _dialogTextFields() => find.descendant(
      of: find.byType(SkotiqDialog),
      matching: find.byType(TextField),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'crud_round_trip: adding a watched folder writes the v58 row, editing '
    'renames it and deleting removes it',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      final targets = DeliveryTargetsDao(database);

      await _pumpDelivery(tester, database);

      expect(
        find.text('No delivery destination'),
        findsOneWidget,
        reason: 'With no rows the card must say nothing is copied off this '
            'machine.',
      );

      await tester.tap(find.text('Add watched folder'));
      await tester.pumpAndSettle();

      await tester.enterText(_dialogTextFields().at(0), 'nas');
      await tester.enterText(_dialogTextFields().at(1), '/mnt/nas/skotiq');
      // The four checkboxes follow the model's declaration order:
      // linear masters, draft render, stage exports, night report.
      await tester.tap(find.byType(SkotiqCheckbox).at(0));
      await tester.tap(find.byType(SkotiqCheckbox).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final created = (await targets.readAll()).destinations;
      expect(created, hasLength(1));
      expect(created.single.name, 'nas');
      expect(created.single.kind, ArtifactDestinationKind.watchedFolder);
      expect(created.single.enabled, isTrue);
      expect(created.single.content, {
        ArtifactContent.linearMasters,
        ArtifactContent.draftRender,
      });
      expect(
        decodeDestinationConfig(created.single.configJson)['path'],
        '/mnt/nas/skotiq',
      );
      expect(
        created.single.secretRef,
        isNull,
        reason: 'A watched folder needs no key material.',
      );

      expect(find.text('nas'), findsOneWidget);
      expect(
        find.textContaining('No delivery has run yet.'),
        findsOneWidget,
        reason:
            'A destination that has never been delivered to must say so, not '
            'imply it is delivering.',
      );
      expect(
        find.textContaining('Sends Linear masters, Draft render'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Edit nas'));
      await tester.pumpAndSettle();
      await tester.enterText(_dialogTextFields().at(0), 'office-nas');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final renamed = (await targets.readAll()).destinations;
      expect(renamed.single.name, 'office-nas');
      expect(
        decodeDestinationConfig(renamed.single.configJson)['path'],
        '/mnt/nas/skotiq',
        reason: 'A rename must not drop the transport config.',
      );

      await tester.tap(find.byTooltip('Edit office-nas'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      // ConfirmDialog's own destructive button.
      await tester.tap(find.widgetWithText(SkotiqButton, 'Delete').last);
      await tester.pumpAndSettle();

      expect((await targets.readAll()).destinations, isEmpty);
      expect(find.text('No delivery destination'), findsOneWidget);
    },
  );

  testWidgets(
    'disabling_a_destination_persists_and_stops_claiming_delivery',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      final targets = DeliveryTargetsDao(database);
      await targets.create(
        name: 'nas',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/nas"}',
        content: {ArtifactContent.linearMasters},
      );

      await _pumpDelivery(tester, database);
      expect(find.textContaining('No delivery has run yet.'), findsOneWidget);

      await tester.tap(find.byType(SkotiqSwitch).first);
      await tester.pumpAndSettle();

      final stored = (await targets.readAll()).destinations;
      expect(stored.single.enabled, isFalse);
      expect(
          find.textContaining('Off — nothing is sent here.'), findsOneWidget);
    },
  );

  testWidgets(
    'masked_secret_never_rendered: the SFTP key is shown only as a masked '
    'indicator, in the row and in the editor',
    (tester) async {
      _swallowKnownOverflows();
      const privateKey = 'BEGIN-OPENSSH-PRIVATE-KEY-do-not-render-me';
      final database = mockDatabase();
      addTearDown(database.close);
      final targets = DeliveryTargetsDao(database);
      final id = await targets.create(
        name: 'office-pc',
        kind: ArtifactDestinationKind.sftp,
        configJson: '{"host":"office.local","port":22,"user":"sean",'
            '"remoteDir":"/srv/astro/incoming"}',
        content: {ArtifactContent.linearMasters},
      );
      final secrets = SecretsStore(InMemorySecureKeyValueStore());
      await secrets.write(deliverySecretRef(id), privateKey);
      await targets.update(id, secretRef: deliverySecretRef(id));

      await _pumpDelivery(tester, database, secrets: secrets);

      expect(find.textContaining(kDeliverySecretPlaceholder), findsOneWidget);
      expect(
        find.textContaining(privateKey),
        findsNothing,
        reason: 'The stored key must never reach the widget tree.',
      );
      expect(
        find.textContaining('sean@office.local:22'),
        findsOneWidget,
        reason: 'The non-secret endpoint is what the row identifies.',
      );

      await tester.tap(find.byTooltip('Edit office-pc'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(privateKey),
        findsNothing,
        reason: 'The editor pre-fills nothing from the keyring.',
      );
      expect(
        find.textContaining(kDeliverySecretPlaceholder),
        findsWidgets,
        reason: 'The key field advertises the stored key as masked.',
      );
    },
  );

  testWidgets(
    'journal_states: each status sentence is read out of delivery_journal',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      final targets = DeliveryTargetsDao(database);
      final journal = DeliveryJournalDao(database);
      final deliveredAt = DateTime.utc(2026, 8, 16, 6, 12);
      // `delivery_journal.job_id` is a foreign key into `darkroom_jobs`, so
      // the night's job has to exist before anything can be journaled against
      // it.
      final jobId = await DarkroomJobsDao(database).enqueue();

      final happy = await targets.create(
        name: 'nas',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/nas"}',
        content: {ArtifactContent.linearMasters},
      );
      for (final file in const ['/out/L.fits', '/out/R.fits']) {
        await journal.recordAttempt(
          targetId: happy,
          jobId: jobId,
          filePath: file,
          bytes: 1020054733,
        );
        await journal.markDelivered(
          targetId: happy,
          jobId: jobId,
          filePath: file,
          checksum: 'abc',
          now: deliveredAt,
        );
      }

      final unreachable = await targets.create(
        name: 'attic-nas',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/attic"}',
        content: {ArtifactContent.linearMasters},
      );
      await journal.recordAttempt(
        targetId: unreachable,
        jobId: jobId,
        filePath: '/out/L.fits',
      );
      await journal.markRetrying(
        targetId: unreachable,
        jobId: jobId,
        filePath: '/out/L.fits',
        error: 'attic-nas is unreachable',
      );

      final broken = await targets.create(
        name: 'usb-drive',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/usb"}',
        content: {ArtifactContent.nightReport},
      );
      await journal.recordAttempt(
        targetId: broken,
        jobId: jobId,
        filePath: '/out/report.txt',
      );
      await journal.markFailed(
        targetId: broken,
        jobId: jobId,
        filePath: '/out/report.txt',
        error: 'the drive filled up',
      );

      final peer = await targets.create(
        name: 'desk',
        kind: ArtifactDestinationKind.peer,
        configJson: '{"peerId":"office-pc"}',
        content: {ArtifactContent.draftRender},
      );
      await journal.recordAttempt(
        targetId: peer,
        jobId: jobId,
        filePath: '/out/draft.jpg',
        bytes: 2048,
      );

      await targets.create(
        name: 'empty-selection',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/nowhere"}',
      );

      await _pumpDelivery(
        tester,
        database,
        pairedDevices: [
          PairedDevice(
            deviceId: 'office-pc',
            deviceName: 'Office PC',
            sessionToken: 'token',
            pairedAt: DateTime.utc(2026, 8, 1),
            lastConnectedAt: DateTime.utc(2026, 8, 15, 22),
            deviceType: 'desktop',
            isActive: true,
            authGrantSpec: 'control',
          ),
        ],
      );

      expect(find.textContaining('Delivered '), findsOneWidget);
      // GiB, not GB: the formatter divides by 1024, and it now labels the
      // unit it actually computes.
      expect(find.textContaining('2 files, 1.9 GiB'), findsOneWidget);
      expect(
        find.textContaining('attic-nas is unreachable — will retry'),
        findsOneWidget,
      );
      expect(
        // The unit belongs to the pair, not to each half: this read
        // "1 file of 1 file failed".
        find.textContaining('1 of 1 file failed — the drive filled up'),
        findsOneWidget,
      );
      expect(
        find.textContaining('waiting for office-pc to pull'),
        findsOneWidget,
        reason:
            'A published peer row is owed a PULL, not a retry — the journal '
            'state is the same and the sentence must not be.',
      );
      expect(find.textContaining('Pairing: Office PC'), findsOneWidget);
      expect(
        find.textContaining('Nothing selected'),
        findsOneWidget,
        reason:
            'A destination with no content selected receives nothing and must '
            'say so.',
      );
    },
  );

  // D3-DEL-1. The page told the operator that an unmatched peer id meant
  // "nothing can pull these files". Proved false against the same build: with
  // `paired_devices` empty, a bearer token completed
  // `GET /api/darkroom/delivery/manifest/<job>?peer=office-pc`, the artifact
  // download and the ack, and the journal row flipped to delivered. The three
  // peer routes authenticate the token and resolve `?peer=` against
  // `delivery_targets`; they never read the pairing store. The line may report
  // what the pairing register holds — it may not claim a capability it does not
  // control.
  testWidgets(
    'a peer row with no matching pairing says nobody is REGISTERED, and names '
    'what actually gates the pull',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      final targets = DeliveryTargetsDao(database);
      final journal = DeliveryJournalDao(database);
      final jobId = await DarkroomJobsDao(database).enqueue();

      final peer = await targets.create(
        name: 'desk',
        kind: ArtifactDestinationKind.peer,
        configJson: '{"peerId":"office-pc"}',
        content: {ArtifactContent.draftRender},
      );
      await journal.recordAttempt(
        targetId: peer,
        jobId: jobId,
        filePath: '/out/draft.jpg',
        bytes: 2048,
      );

      await _pumpDelivery(tester, database);

      expect(
        find.textContaining('no paired desktop is registered under '
            '"office-pc"'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'served to any client holding this rig\'s access token',
        ),
        findsOneWidget,
        reason: 'the token is the gate, so the token is what the page names',
      );
      expect(
        find.textContaining('nothing can pull these files'),
        findsNothing,
        reason:
            'the same build serves and acknowledges exactly those files with '
            'the pairing store empty',
      );
    },
  );

  testWidgets(
    'newest_job_outranks_newest_touched_row: a failing latest night is not '
    'hidden by an older night the sweep finally delivered',
    (tester) async {
      // The shape that hid a lost night. `listForTarget` orders by
      // `updated_at`, and the overnight sweep writes `updated_at` on rows from
      // OLDER jobs — so the row at the top of that list belonged to the night
      // before last, and this page reported ITS verdict. An operator whose
      // latest night failed and whose previous night was finally delivered at
      // 06:20 read a green "Delivered 06:20" and no sign of the failure.
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      final targets = DeliveryTargetsDao(database);
      final journal = DeliveryJournalDao(database);
      final jobs = DarkroomJobsDao(database);

      final nightBeforeLast = DateTime.utc(2026, 8, 14, 6, 10);
      final lastNight = DateTime.utc(2026, 8, 15, 6, 5);
      final thisMorning = DateTime.utc(2026, 8, 16, 6, 20);

      final target = await targets.create(
        name: 'nas',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/nas"}',
        content: {ArtifactContent.linearMasters},
      );
      final olderJob = await jobs.enqueue();
      final newerJob = await jobs.enqueue();

      await journal.recordAttempt(
        targetId: target,
        jobId: olderJob,
        filePath: '/out/night14_L.fits',
        bytes: 1024,
        now: nightBeforeLast,
      );
      await journal.markRetrying(
        targetId: target,
        jobId: olderJob,
        filePath: '/out/night14_L.fits',
        error: 'destinationUnreachable: the share was not mounted',
        now: nightBeforeLast,
      );
      await journal.recordAttempt(
        targetId: target,
        jobId: newerJob,
        filePath: '/out/night15_L.fits',
        bytes: 2048,
        now: lastNight,
      );
      await journal.markFailed(
        targetId: target,
        jobId: newerJob,
        filePath: '/out/night15_L.fits',
        error: 'destinationConflict: that name is already there',
        now: lastNight,
      );
      // The sweep gets the older night onto the NAS this morning, which makes
      // its row the newest-TOUCHED row on this destination.
      await journal.markDelivered(
        targetId: target,
        jobId: olderJob,
        filePath: '/out/night14_L.fits',
        checksum: 'abc',
        now: thisMorning,
      );

      final rows = await journal.listForTarget(target);
      expect(
        rows.first.jobId,
        olderJob,
        reason: 'the premise: the newest-touched row belongs to the OLDER job',
      );

      await _pumpDelivery(tester, database);

      expect(
        find.textContaining('destinationConflict'),
        findsOneWidget,
        reason: 'the latest night failed, and that is what the row must say',
      );
      expect(
        find.textContaining('Delivered '),
        findsNothing,
        reason: 'an older night delivered at 06:20 is not this destination\'s '
            'current verdict, and painting it green hides a lost night',
      );
    },
  );

  testWidgets(
    'stranded_older_failures_outrank_a_newer_clean_run, and the page offers '
    'the retry that reaches them',
    (tester) async {
      // The wave-7 shape, read off the release bundle: `case8-strand` held
      // four of job 4's drafts `failed` with destinationConflict and four of
      // job 5's `delivered`. The row read "Delivered 17:55, 4 files, 1.4 MiB."
      // in green, said nothing about the four, and offered no way to retry
      // them — while nothing on the rig was ever going to look at them again.
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      final targets = DeliveryTargetsDao(database);
      final journal = DeliveryJournalDao(database);
      final jobs = DarkroomJobsDao(database);

      final strandedNight = DateTime.utc(2026, 8, 15, 6, 5);
      final lastNight = DateTime.utc(2026, 8, 16, 6, 10);

      final target = await targets.create(
        name: 'case8-strand',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/nas"}',
        content: {ArtifactContent.draftRender},
      );
      final strandedJob = await jobs.enqueue();
      final newJob = await jobs.enqueue();

      for (var i = 1; i <= 4; i++) {
        await journal.recordAttempt(
          targetId: target,
          jobId: strandedJob,
          filePath: '/out/job4_master_${i}_draft.jpg',
          bytes: 350000,
          now: strandedNight,
        );
        await journal.markFailed(
          targetId: target,
          jobId: strandedJob,
          filePath: '/out/job4_master_${i}_draft.jpg',
          error: 'destinationConflict: a different file already holds that '
              'name',
          now: strandedNight,
        );
        await journal.recordAttempt(
          targetId: target,
          jobId: newJob,
          filePath: '/out/job5_master_${i}_draft.jpg',
          bytes: 350000,
          now: lastNight,
        );
        await journal.markDelivered(
          targetId: target,
          jobId: newJob,
          filePath: '/out/job5_master_${i}_draft.jpg',
          checksum: 'abc$i',
          now: lastNight,
        );
      }

      var sweeps = 0;
      await _pumpDelivery(
        tester,
        database,
        sweep: () async {
          sweeps++;
          return null;
        },
      );

      expect(
        find.textContaining('4 files never arrived'),
        findsOneWidget,
        reason: 'four files are stranded at this destination; the newest '
            'night delivering cleanly does not un-strand them',
      );
      expect(
        find.textContaining('Delivered '),
        findsNothing,
        reason: 'a red truth outranks a newer green when files never arrived',
      );

      await tester.tap(find.text('Retry now'));
      await tester.pumpAndSettle();

      final after = await journal.listForTarget(target);
      expect(
        after.where((e) => e.jobId == strandedJob).map((e) => e.state),
        everyElement(DeliveryAttemptState.retrying),
        reason: 'the control beside that sentence has to reach the files it '
            'names',
      );
      expect(sweeps, 1);
    },
  );

  testWidgets(
    'a watched folder whose directory is not there says so on the row',
    (tester) async {
      // The editor's write probe refuses "/mnt/nowhere/skotiq" honestly.
      // Saving past that refusal used to produce a row that said only "No
      // delivery has run yet." — the page's own contract is that a channel
      // going nowhere says so in that same sentence slot.
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      final targets = DeliveryTargetsDao(database);

      await targets.create(
        name: 'nas',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/nowhere/skotiq"}',
        content: {ArtifactContent.nightReport},
      );

      await _pumpDelivery(
        tester,
        database,
        folderExists: (path) async => path != '/mnt/nowhere/skotiq',
      );

      expect(
        find.textContaining(
          'There is no directory at /mnt/nowhere/skotiq',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('No delivery has run yet.'),
        findsNothing,
        reason: 'that sentence reads as a destination merely waiting for its '
            'first night, which this one is not',
      );
    },
  );

  testWidgets(
    'retry_now_requeues_every_terminal_row_the_status_line_counts',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      final targets = DeliveryTargetsDao(database);
      final journal = DeliveryJournalDao(database);
      final jobs = DarkroomJobsDao(database);

      final target = await targets.create(
        name: 'nas',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/nas"}',
        content: {ArtifactContent.linearMasters},
      );
      final oldJob = await jobs.enqueue();
      final newJob = await jobs.enqueue();
      // An older night's failure. Nothing on the rig will look at it again:
      // the sweep reads only `retrying` rows, so this file is as lost as the
      // newest night's until somebody re-queues it.
      await journal.recordAttempt(
        targetId: target,
        jobId: oldJob,
        filePath: '/out/old.fits',
        now: DateTime.utc(2026, 8, 14, 6),
      );
      await journal.markFailed(
        targetId: target,
        jobId: oldJob,
        filePath: '/out/old.fits',
        error: 'destinationUnreachable: gone',
        now: DateTime.utc(2026, 8, 14, 6),
      );
      for (final file in const ['/out/L.fits', '/out/R.fits']) {
        await journal.recordAttempt(
          targetId: target,
          jobId: newJob,
          filePath: file,
          now: DateTime.utc(2026, 8, 16, 6),
        );
        await journal.markFailed(
          targetId: target,
          jobId: newJob,
          filePath: file,
          error: 'destinationConflict: that name is already there',
          now: DateTime.utc(2026, 8, 16, 6),
        );
      }

      var sweeps = 0;
      await _pumpDelivery(
        tester,
        database,
        sweep: () async {
          sweeps++;
          return null;
        },
      );

      expect(
        find.text('Retry now'),
        findsOneWidget,
        reason: 'a spent row is the end of the line until somebody says '
            'otherwise, so the page has to offer that somewhere',
      );

      await tester.tap(find.text('Retry now'));
      await tester.pumpAndSettle();

      final requeued = await journal.listForTarget(target);
      expect(requeued, hasLength(3));
      for (final entry in requeued) {
        expect(entry.state, DeliveryAttemptState.retrying);
        expect(
          entry.attempts,
          0,
          reason: 'the budget is reset, or the row is terminal again on its '
              'first attempt',
        );
      }
      expect(
        requeued.singleWhere((e) => e.jobId == oldJob).state,
        DeliveryAttemptState.retrying,
        reason: 'the sentence beside this button counts the older night too, '
            'so a button that left it behind would report work it did not do',
      );
      expect(sweeps, 1, reason: '"Retry now" asks for a pass, not just a row');
      expect(find.textContaining('Re-queued 3 files'), findsOneWidget);
    },
  );

  testWidgets(
    'editing_a_destination_requeues_what_the_edit_was_for',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      final targets = DeliveryTargetsDao(database);
      final journal = DeliveryJournalDao(database);
      final jobs = DarkroomJobsDao(database);

      final target = await targets.create(
        name: 'nas',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/wrong"}',
        content: {ArtifactContent.linearMasters},
      );
      final job = await jobs.enqueue();
      await journal.recordAttempt(
        targetId: target,
        jobId: job,
        filePath: '/out/L.fits',
      );
      await journal.markFailed(
        targetId: target,
        jobId: job,
        filePath: '/out/L.fits',
        error: 'destinationUnreachable: /mnt/wrong is not on the filesystem',
      );

      await _pumpDelivery(tester, database);
      await tester.tap(find.byTooltip('Edit nas'));
      await tester.pumpAndSettle();
      await tester.enterText(_dialogTextFields().at(1), '/mnt/right');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(
        decodeDestinationConfig(
          (await targets.readAll()).destinations.single.configJson,
        )['path'],
        '/mnt/right',
      );
      final entry = (await journal.listForTarget(target)).single;
      expect(
        entry.state,
        DeliveryAttemptState.retrying,
        reason: 'fixing the folder is the operator answering the failure; a '
            'row left spent means the fix delivers nothing',
      );
      expect(entry.attempts, 0);
    },
  );

  testWidgets(
    'name_assertion_clears_when_the_field_gains_text',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);

      await _pumpDelivery(tester, database);
      await tester.tap(find.text('Add watched folder'));
      await tester.pumpAndSettle();

      // Save with the form empty: the assertion appears.
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('This destination needs a name.'), findsOneWidget);
      // On the Name field itself, not in a footer ~470px below the box it is
      // about: `SkotiqTextField.errorText` paints under its own box and
      // turns the border red, which is what makes the sentence point at the
      // field it is about.
      expect(
        tester
            .widget<SkotiqTextField>(
              find.widgetWithText(SkotiqTextField, 'Name'),
            )
            .errorText,
        'This destination needs a name.',
      );

      // Typing the name answers it. As a footer string it survived the
      // keystroke that answered it, so the form went on asserting "This
      // destination needs a name." over a Name field holding `nas` — and the
      // next Save succeeded, proving the sentence had been stale all along.
      await tester.enterText(_dialogTextFields().at(0), 'nas');
      await tester.pumpAndSettle();
      expect(find.text('This destination needs a name.'), findsNothing);
      expect(
        tester
            .widget<SkotiqTextField>(
              find.widgetWithText(SkotiqTextField, 'Name'),
            )
            .errorText,
        isNull,
      );
    },
  );

  testWidgets(
    'peer_without_pairing_reports_the_register_not_a_capability',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      await DeliveryTargetsDao(database).create(
        name: 'desk',
        kind: ArtifactDestinationKind.peer,
        configJson: '{"peerId":"office-pc"}',
        content: {ArtifactContent.draftRender},
      );

      await _pumpDelivery(tester, database);

      expect(find.text('Paired desktop pulls'.toUpperCase()), findsWidgets);
      expect(
        find.textContaining(
          'no paired desktop is registered under "office-pc"',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'sftp_without_a_key_refuses_to_look_configured',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      await DeliveryTargetsDao(database).create(
        name: 'office-pc',
        kind: ArtifactDestinationKind.sftp,
        configJson: '{"host":"office.local","port":22,"user":"sean",'
            '"remoteDir":"/srv/astro"}',
        content: {ArtifactContent.linearMasters},
      );

      await _pumpDelivery(tester, database);

      expect(
        find.textContaining('No key in the keyring'),
        findsOneWidget,
        reason:
            'Without a key SSH cannot authenticate, so the row must not read '
            'as ready.',
      );
      expect(find.textContaining('SSH key: none stored'), findsOneWidget);
    },
  );

  testWidgets(
    'mobile_layout_does_not_overflow: a long remote path is clipped inside '
    'the card, not painted past its edge',
    (tester) async {
      // Deliberately NOT swallowing overflow errors: this test exists to fail
      // when a destination row paints outside its card on a phone.
      final database = mockDatabase();
      addTearDown(database.close);
      await DeliveryTargetsDao(database).create(
        name: 'observatory-nas-in-the-garden-shed',
        kind: ArtifactDestinationKind.sftp,
        configJson: '{"host":"observatory.longer.example.internal","port":2222,'
            '"user":"astrophotographer",'
            '"remoteDir":"/srv/astro/incoming/skotiq/masters/2026"}',
        content: ArtifactContent.values.toSet(),
      );

      await pumpAppScreen(
        tester,
        const DeliverySettings(isMobile: true),
        database: database,
        size: const Size(360, 740),
        extraOverrides: _overrides(),
      );

      expect(find.text('observatory-nas-in-the-garden-shed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sftp_key_goes_to_the_keyring_and_never_into_config_json',
    (tester) async {
      _swallowKnownOverflows();
      const privateKey = 'BEGIN-OPENSSH-PRIVATE-KEY-keyring-only';
      final database = mockDatabase();
      addTearDown(database.close);
      final targets = DeliveryTargetsDao(database);
      final secrets = SecretsStore(InMemorySecureKeyValueStore());

      await _pumpDelivery(tester, database, secrets: secrets);
      await tester.tap(find.text('Add SFTP destination'));
      await tester.pumpAndSettle();

      // The transport's name is spelled once, in `deliveryKindLabel`, and every
      // surface inherits that spelling. This header lowercased it and read
      // "Add sftp" under the button that opened it.
      expect(find.text('Add SFTP'), findsOneWidget);
      expect(find.text('Add sftp'), findsNothing);

      // Name, Host, Port, User, Remote directory, Private key.
      await tester.enterText(_dialogTextFields().at(0), 'office-pc');
      await tester.enterText(_dialogTextFields().at(1), 'office.local');
      await tester.enterText(_dialogTextFields().at(3), 'sean');
      await tester.enterText(_dialogTextFields().at(4), '/srv/astro');
      await tester.enterText(_dialogTextFields().at(5), privateKey);
      await tester.tap(find.byType(SkotiqCheckbox).at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final stored = (await targets.readAll()).destinations;
      expect(stored, hasLength(1));
      final secretRef = stored.single.secretRef;
      expect(secretRef, isNotNull);
      expect(await secrets.read(secretRef!), privateKey);
      expect(
        stored.single.configJson.contains(privateKey),
        isFalse,
        reason:
            'config_json rides export and backup, so key material must never '
            'be written there.',
      );
      // The v58 guard the DAO applies on every write, restated here so a
      // future editor field that smuggles a credential fails this test.
      assertNoSecretsInConfig(stored.single.configJson);

      await tester.tap(find.byTooltip('Edit office-pc'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove stored key'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final cleared = (await targets.readAll()).destinations;
      expect(cleared.single.secretRef, isNull);
      expect(await secrets.has(secretRef), isFalse);
      expect(find.textContaining('No key in the keyring'), findsOneWidget);
    },
  );

  testWidgets(
    'a11y_semantics: the per-destination controls name the destination they '
    'act on',
    (tester) async {
      _swallowKnownOverflows();
      final semantics = tester.ensureSemantics();

      final database = mockDatabase();
      addTearDown(database.close);
      await DeliveryTargetsDao(database).create(
        name: 'nas',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/nas"}',
        content: {ArtifactContent.linearMasters},
      );

      await _pumpDelivery(tester, database);

      expect(find.bySemanticsLabel(RegExp('Deliver to nas')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Edit nas')), findsOneWidget);

      // Disposed inside the body: the framework verifies no handle is live
      // before `addTearDown` callbacks run.
      semantics.dispose();
    },
  );

  // Naming the controls is not enough if they are not controls. A row-wide
  // MergeSemantics folded the switch, the Edit button and every line of the
  // description into ONE checkable node whose name was the whole card —
  // "nas / Watched folder · /mnt/nas / No delivery has run yet. / Sends Linear
  // masters / Deliver to nas / Edit nas [ON]" — so a screen reader had one
  // button that did nothing when activated, no toggle and no way to reach the
  // editor. Contrast the step cards, which publish the toggle, the parameters
  // button and Remove separately.
  testWidgets(
    'a11y_nodes: the destination row publishes its toggle, its editor and its '
    'description as separate nodes',
    (tester) async {
      _swallowKnownOverflows();
      final semantics = tester.ensureSemantics();

      final database = mockDatabase();
      addTearDown(database.close);
      await DeliveryTargetsDao(database).create(
        name: 'nas',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/nas"}',
        content: {ArtifactContent.linearMasters},
      );

      await _pumpDelivery(tester, database);

      // The switch is its own node: named for the destination it delivers to,
      // carrying the on/off state and nothing else. The name is EXACTLY that —
      // when the row merged, this label was only a fragment of a 5-line blob.
      final toggleNode = tester.getSemantics(
        find.bySemanticsLabel('Deliver to nas'),
      );
      final toggle = toggleNode.getSemanticsData();
      expect(toggle.label, 'Deliver to nas');
      expect(
        toggle.flagsCollection.isToggled,
        Tristate.isTrue,
        reason: 'the switch must arrive as a switch reporting its own state, '
            'not as a plain button',
      );

      // The editor is a second node, and it is the one carrying the tap.
      final editNode = tester.getSemantics(find.bySemanticsLabel('Edit nas'));
      final edit = editNode.getSemanticsData();
      expect(edit.label, 'Edit nas');
      expect(edit.hasAction(SemanticsAction.tap), isTrue);
      expect(
        editNode.id,
        isNot(toggleNode.id),
        reason: 'one node cannot be both the switch and the editor',
      );

      // The body is a third node: it says what the destination is and what the
      // journal reports, and it claims no action, because activating it does
      // nothing.
      final body = tester
          .getSemantics(
            find.descendant(
              of: find.byType(MergeSemantics),
              matching: find.text('nas'),
            ),
          )
          .getSemanticsData();
      expect(body.label, contains('Watched folder · /mnt/nas'));
      expect(body.label, contains('Sends Linear masters'));
      expect(
        body.label,
        isNot(contains('Edit nas')),
        reason: 'the description must not swallow the controls beside it',
      );
      expect(
        body.hasAction(SemanticsAction.tap),
        isFalse,
        reason: 'a row body that does nothing when activated must not offer '
            'an activation',
      );
      expect(
        body.flagsCollection.isToggled,
        Tristate.none,
        reason: 'the description is not a switch and must not report one',
      );

      semantics.dispose();
    },
  );

  testWidgets(
    'remote_mode_refuses_to_show_this_device_rows_as_the_hosts',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      await DeliveryTargetsDao(database).create(
        name: 'local-only',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/local"}',
        content: {ArtifactContent.linearMasters},
      );

      await pumpAppScreen(
        tester,
        const DeliverySettings(),
        database: database,
        size: const Size(1280, 1000),
        extraOverrides: [
          ..._overrides(),
          isRemoteModeProvider.overrideWithValue(true),
        ],
      );

      expect(
        find.text('Delivery destinations live on the imaging host'),
        findsOneWidget,
      );
      expect(
        find.text('local-only'),
        findsNothing,
        reason: 'This device\'s own rows are not the host\'s and must not be '
            'presented as them.',
      );
    },
  );

  testWidgets(
    'a client launched against a host it has not reached yet is still a client',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      await DeliveryTargetsDao(database).create(
        name: 'local-only',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/local"}',
        content: {ArtifactContent.linearMasters},
      );

      await pumpAppScreen(
        tester,
        const DeliverySettings(),
        database: database,
        size: const Size(1280, 1000),
        extraOverrides: [
          ..._overrides(),
          // The launch flags said `--remote-host`; the handshake has not landed
          // (or has dropped), so the connection-shaped gate reads false. A
          // destination added here would go into a database no dawn job reads.
          remoteClientLaunchProvider.overrideWithValue(true),
          isRemoteModeProvider.overrideWithValue(false),
        ],
      );

      expect(
        find.text('Delivery destinations live on the imaging host'),
        findsOneWidget,
      );
      expect(find.text('Add watched folder'), findsNothing);
      expect(find.text('local-only'), findsNothing);
    },
  );

  testWidgets(
    'a host launch keeps its own destination editor',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);

      await pumpAppScreen(
        tester,
        const DeliverySettings(),
        database: database,
        size: const Size(1280, 1000),
        extraOverrides: [
          ..._overrides(),
          remoteClientLaunchProvider.overrideWithValue(false),
          isRemoteModeProvider.overrideWithValue(false),
        ],
      );

      expect(
        find.text('Delivery destinations live on the imaging host'),
        findsNothing,
      );
      expect(find.text('Add watched folder'), findsOneWidget);
    },
  );

  testWidgets(
    'undecodable_row_is_its_own_failure: the page still lists the '
    'destinations that decode, and names the one that does not',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      await DeliveryTargetsDao(database).create(
        name: 'good-nas',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/nas"}',
        content: {ArtifactContent.linearMasters},
      );
      // An artifact class this build does not know, exactly as a newer build
      // or a hand edit leaves it. `content_json` carries no CHECK, so SQLite
      // stores it as written.
      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      await database.customStatement(
        'INSERT INTO delivery_targets('
        'name, kind, config_json, enabled, content_json, created_at, '
        'updated_at) VALUES (?, ?, ?, 1, ?, ?, ?)',
        ['bad-row', 'watched_folder', '{}', '["hdr_composite"]', now, now],
      );

      await _pumpDelivery(tester, database);

      // The page renders — it does not fall back to its error state.
      expect(find.text('Failed to load settings'), findsNothing);
      expect(find.text('good-nas'), findsOneWidget);
      expect(find.text('Add watched folder'), findsOneWidget);

      // And the row that will not decode is on the page as itself.
      expect(find.text('bad-row'), findsOneWidget);
      expect(
        find.textContaining('hdr_composite'),
        findsOneWidget,
        reason: 'the operator has to be told WHICH value stopped the row',
      );
      // `content_json` is not CHECK-constrained; claiming it is points at a
      // database rule that never ran.
      expect(find.textContaining('CHECK-constrained'), findsNothing);
    },
  );

  testWidgets(
    'undecodable_row_can_be_deleted: the one action a row nothing can read '
    'still needs',
    (tester) async {
      _swallowKnownOverflows();
      final database = mockDatabase();
      addTearDown(database.close);
      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      await database.customStatement(
        'INSERT INTO delivery_targets('
        'name, kind, config_json, enabled, content_json, created_at, '
        'updated_at) VALUES (?, ?, ?, 1, ?, ?, ?)',
        ['bad-row', 'watched_folder', '{}', '["hdr_composite"]', now, now],
      );

      await _pumpDelivery(tester, database);

      await tester.tap(find.widgetWithText(SkotiqButton, 'Delete').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SkotiqButton, 'Delete').last);
      await tester.pumpAndSettle();

      final rows =
          await database.customSelect('SELECT id FROM delivery_targets').get();
      expect(rows, isEmpty);
      expect(find.text('No delivery destination'), findsOneWidget);
    },
  );

  // The unreadable row carries the page's one destructive control, and it was
  // merged into the row's description in the same way — a 4-line name ending
  // in "Delete". A screen reader must be able to find Delete as Delete.
  testWidgets(
    'a11y_nodes: the unreadable row keeps Delete as a control of its own',
    (tester) async {
      _swallowKnownOverflows();
      final semantics = tester.ensureSemantics();

      final database = mockDatabase();
      addTearDown(database.close);
      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      await database.customStatement(
        'INSERT INTO delivery_targets('
        'name, kind, config_json, enabled, content_json, created_at, '
        'updated_at) VALUES (?, ?, ?, 1, ?, ?, ?)',
        ['bad-row', 'watched_folder', '{}', '["hdr_composite"]', now, now],
      );

      await _pumpDelivery(tester, database);

      final delete = tester
          .getSemantics(find.widgetWithText(SkotiqButton, 'Delete'))
          .getSemanticsData();
      expect(delete.label, contains('Delete'));
      expect(delete.hasAction(SemanticsAction.tap), isTrue);
      expect(
        delete.label,
        isNot(contains('This row cannot be read')),
        reason: 'the button is named for what it does, not for the whole row',
      );

      final body = tester
          .getSemantics(
            find.descendant(
              of: find.byType(MergeSemantics),
              matching: find.text('bad-row'),
            ),
          )
          .getSemanticsData();
      expect(body.label, contains('This row cannot be read'));
      expect(
        body.label,
        isNot(contains('Delete')),
        reason: 'the explanation must not absorb the button that acts on it',
      );

      semantics.dispose();
    },
  );
}
