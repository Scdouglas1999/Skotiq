// Pins the results of the Darkroom DAOs (jobs, delivery destinations, the
// delivery journal, recipes) on a seeded database: typed job transitions and
// the errors they raise, COALESCE partial updates, the journal upserts and
// their guard on delivered rows, per-row decode isolation, the recipe branch
// graph, and the rows each write leaves behind.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/darkroom_jobs_dao.dart';
import 'package:skotiq_core/src/database/daos/delivery_journal_dao.dart';
import 'package:skotiq_core/src/database/daos/delivery_targets_dao.dart';
import 'package:skotiq_core/src/database/daos/recipes_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/darkroom/darkroom_job.dart';
import 'package:skotiq_core/src/models/darkroom/delivery.dart';
import 'package:skotiq_core/src/models/darkroom/recipe.dart';

import 'pin_harness.dart';

Object? _encode(Object value) => switch (value) {
  DarkroomJob j => {
    'id': j.id,
    'sessionId': j.sessionId,
    'kind': j.kind,
    'state': j.state,
    'progress': j.progress,
    'note': j.note,
    'errorText': j.errorText,
    'attempts': j.attempts,
    'createdAt': j.createdAt,
    'startedAt': j.startedAt,
    'finishedAt': j.finishedAt,
  },
  ArtifactDestination d => {
    'id': d.id,
    'name': d.name,
    'kind': d.kind,
    'configJson': d.configJson,
    'enabled': d.enabled,
    'content': [for (final c in d.content) c],
    'secretRef': d.secretRef,
    'createdAt': d.createdAt,
    'updatedAt': d.updatedAt,
  },
  DeliveryTargetsRead r => {
    'destinations': r.destinations,
    'undecodable': r.undecodable,
  },
  UndecodableDeliveryTarget u => {
    'id': u.id,
    'name': u.name,
    'reason': u.reason,
    'label': u.label,
  },
  DeliveryJournalEntry e => {
    'id': e.id,
    'targetId': e.targetId,
    'jobId': e.jobId,
    'filePath': e.filePath,
    'bytes': e.bytes,
    'checksum': e.checksum,
    'state': e.state,
    'attempts': e.attempts,
    'lastError': e.lastError,
    'createdAt': e.createdAt,
    'updatedAt': e.updatedAt,
    'deliveredAt': e.deliveredAt,
  },
  DarkroomRecipe r => {
    'id': r.id,
    'targetId': r.targetId,
    'sessionId': r.sessionId,
    'masterId': r.masterId,
    'baseMasterPath': r.baseMasterPath,
    'name': r.name,
    'stepsJson': r.stepsJson,
    'createdBy': r.createdBy,
    'parentRecipeId': r.parentRecipeId,
    'divergenceIndex': r.divergenceIndex,
    'schemaVersion': r.schemaVersion,
    'createdAt': r.createdAt,
    'updatedAt': r.updatedAt,
  },
  RecipeDraftNote n => n.toJson(),
  _ => null,
};

void main() {
  late SkotiqDatabase db;
  late PinSeed seed;

  setUp(() async {
    db = openPinDatabase();
    seed = await PinSeed.create(db);
  });

  tearDown(() => db.close());

  test('DarkroomJobsDao results are pinned', () async {
    final pins = PinRecorder('darkroom_jobs_dao', encode: _encode);
    final dao = DarkroomJobsDao(db);
    final s0 = seed.sessions[0];

    await pins('empty getById', () => dao.getById(1));
    await pins('empty nextQueued', dao.nextQueued);
    await pins(
      'empty listByState',
      () => dao.listByState(DarkroomJobState.queued),
    );

    await pins(
      'enqueue a',
      () => dao.enqueue(sessionId: s0, note: 'dawn pass', createdAt: pinT(10)),
    );
    await pins(
      'enqueue b tie',
      () => dao.enqueue(
        sessionId: s0,
        kind: DarkroomJobKind.manual,
        createdAt: pinT(10),
      ),
    );
    await pins('enqueue c older', () => dao.enqueue(createdAt: pinT(5)));
    await pins('enqueue d now', () => dao.enqueue(sessionId: seed.sessions[1]));
    await pins.dump(db, 'darkroom_jobs', 'after enqueue');

    await pins('nextQueued', dao.nextQueued);
    await pins(
      'listByState queued',
      () => dao.listByState(DarkroomJobState.queued),
    );
    await pins('listForSession s0', () => dao.listForSession(s0));
    await pins('listForSession none', () => dao.listForSession(999));

    await pins('markRunning 1', () => dao.markRunning(1, now: pinT(20)));
    await pins('markRunning 1 again', () => dao.markRunning(1, now: pinT(21)));
    await pins('markRunning missing', () => dao.markRunning(99));
    await pins('updateProgress 1', () => dao.updateProgress(1, 0.25));
    await pins(
      'updateProgress 1 note',
      () => dao.updateProgress(1, 0.5, note: 'stacking Ha'),
    );
    await pins('updateProgress out of range', () => dao.updateProgress(1, 1.5));
    await pins('updateProgress queued', () => dao.updateProgress(2, 0.1));
    await pins('noteWhileQueued 2', () => dao.noteWhileQueued(2, 'waiting'));
    await pins('noteWhileQueued running', () => dao.noteWhileQueued(1, 'x'));
    await pins('noteWhileQueued missing', () => dao.noteWhileQueued(99, 'x'));
    await pins('markDone 1', () => dao.markDone(1, now: pinT(30)));
    await pins('markDone 1 again', () => dao.markDone(1, now: pinT(31)));
    await pins('markDone queued', () => dao.markDone(2, now: pinT(31)));
    await pins('markRunning 2', () => dao.markRunning(2, now: pinT(32)));
    await pins(
      'markFailed 2',
      () => dao.markFailed(2, 'disk full', now: pinT(33)),
    );
    await pins('markRunning 3', () => dao.markRunning(3, now: pinT(34)));
    await pins(
      'releaseForOrderlyStop 3',
      () => dao.releaseForOrderlyStop(3, note: 'service stopping'),
    );
    await pins(
      'releaseForOrderlyStop queued',
      () => dao.releaseForOrderlyStop(3),
    );
    await db.customStatement(
      "UPDATE darkroom_jobs SET state = 'running', attempts = 0 WHERE id = 3",
    );
    await pins(
      'releaseForOrderlyStop zero attempts',
      () => dao.releaseForOrderlyStop(3),
    );
    await pins(
      'markCancelled 3 reason',
      () => dao.markCancelled(3, reason: 'operator', now: pinT(35)),
    );
    await pins('markRunning 4', () => dao.markRunning(4, now: pinT(36)));
    await pins(
      'markDone 4 note',
      () => dao.markDone(4, note: 'all done', now: pinT(37)),
    );
    await pins('markCancelled done', () => dao.markCancelled(4));
    await pins.dump(db, 'darkroom_jobs', 'after transitions');

    await pins(
      'listByState done',
      () => dao.listByState(DarkroomJobState.done),
    );
    await pins('deleteJob 4', () => dao.deleteJob(4));
    await pins('deleteJob missing', () => dao.deleteJob(4));
    await pins.dump(db, 'darkroom_jobs', 'after delete');
    pins.verify();
  });

  test('DeliveryTargetsDao results are pinned', () async {
    final pins = PinRecorder('delivery_targets_dao', encode: _encode);
    final dao = DeliveryTargetsDao(db);

    await pins('empty readAll', dao.readAll);
    await pins('empty readEnabled', dao.readEnabled);
    await pins('empty getById', () => dao.getById(1));
    await pins('empty secretRefOf', () => dao.secretRefOf(1));

    await pins(
      'create folder',
      () => dao.create(
        name: 'NAS',
        kind: ArtifactDestinationKind.watchedFolder,
        configJson: '{"path":"/mnt/nas"}',
        content: {ArtifactContent.nightReport, ArtifactContent.linearMasters},
        createdAt: pinT(10),
      ),
    );
    await pins(
      'create sftp disabled tie',
      () => dao.create(
        name: 'Remote',
        kind: ArtifactDestinationKind.sftp,
        enabled: false,
        secretRef: 'sftp-key-1',
        createdAt: pinT(10),
        updatedAt: pinT(12),
      ),
    );
    await pins(
      'create peer older',
      () => dao.create(
        name: 'Desk',
        kind: ArtifactDestinationKind.peer,
        createdAt: pinT(2),
      ),
    );
    await pins(
      'create default time',
      () => dao.create(name: 'Now', kind: ArtifactDestinationKind.sftp),
    );
    await pins(
      'create empty name',
      () => dao.create(name: '', kind: ArtifactDestinationKind.peer),
    );
    await pins(
      'create secret in config',
      () => dao.create(
        name: 'Bad',
        kind: ArtifactDestinationKind.sftp,
        configJson: '{"password":"hunter2"}',
      ),
    );
    await pins(
      'create config not object',
      () => dao.create(
        name: 'Bad',
        kind: ArtifactDestinationKind.sftp,
        configJson: '[1]',
      ),
    );
    await pins.dump(db, 'delivery_targets', 'after create');

    await pins('readAll', dao.readAll);
    await pins('readEnabled', dao.readEnabled);
    await pins('getById 2', () => dao.getById(2));
    await pins('secretRefOf 2', () => dao.secretRefOf(2));
    await pins('secretRefOf 1 none', () => dao.secretRefOf(1));

    await pins(
      'update partial',
      () => dao.update(2, name: 'Remote box', enabled: true, now: pinT(20)),
    );
    await pins(
      'update content and config',
      () => dao.update(
        1,
        configJson: '{"path":"/mnt/other"}',
        content: const {},
        secretRef: 'nas-ref',
        now: pinT(21),
      ),
    );
    await pins('update nothing', () => dao.update(3, now: pinT(22)));
    await pins('update missing', () => dao.update(99, name: 'x'));
    await pins(
      'update secret config',
      () => dao.update(1, configJson: '{"privateKey":"abc"}'),
    );
    await pins('clearSecretRef', () => dao.clearSecretRef(2, now: pinT(23)));
    await pins('clearSecretRef missing', () => dao.clearSecretRef(99));
    await pins('update default now', () => dao.update(3, enabled: false));
    await pins.dump(db, 'delivery_targets', 'after update');

    await db.customStatement(
      "UPDATE delivery_targets SET content_json = '[\"future_class\"]' "
      'WHERE id = 1',
    );
    await db.customStatement(
      "UPDATE delivery_targets SET content_json = 'nope', name = '  ' "
      'WHERE id = 3',
    );
    await db.customStatement(
      "UPDATE delivery_targets SET created_at = 'yesterday' WHERE id = 4",
    );
    await pins('readAll with undecodable', dao.readAll);
    await pins('readEnabled with undecodable', dao.readEnabled);
    await pins('getById undecodable', () => dao.getById(1));
    await pins('secretRefOf undecodable', () => dao.secretRefOf(1));

    await pins('deleteTarget 2', () => dao.deleteTarget(2));
    await pins('deleteTarget missing', () => dao.deleteTarget(2));
    await pins.dump(db, 'delivery_targets', 'after delete');
    pins.verify();
  });

  test('DeliveryJournalDao results are pinned', () async {
    final pins = PinRecorder('delivery_journal_dao', encode: _encode);
    final dao = DeliveryJournalDao(db);
    final jobs = DarkroomJobsDao(db);
    final targets = DeliveryTargetsDao(db);
    final job1 = await jobs.enqueue(createdAt: pinT(0));
    final job2 = await jobs.enqueue(createdAt: pinT(0));
    final nas = await targets.create(
      name: 'NAS',
      kind: ArtifactDestinationKind.watchedFolder,
      createdAt: pinT(0),
    );
    final peer = await targets.create(
      name: 'Peer',
      kind: ArtifactDestinationKind.peer,
      createdAt: pinT(0),
    );

    await pins(
      'empty getEntry',
      () => dao.getEntry(targetId: nas, jobId: job1, filePath: '/a'),
    );
    await pins('empty listForJob', () => dao.listForJob(job1));
    await pins('empty listPendingRetry', dao.listPendingRetry);

    await pins(
      'recordAttempt new no bytes',
      () => dao.recordAttempt(
        targetId: nas,
        jobId: job1,
        filePath: '/m/L.fits',
        now: pinT(10),
      ),
    );
    await pins(
      'recordAttempt again with bytes',
      () => dao.recordAttempt(
        targetId: nas,
        jobId: job1,
        filePath: '/m/L.fits',
        bytes: 4096,
        now: pinT(11),
      ),
    );
    await pins(
      'recordAttempt again zero bytes keeps size',
      () => dao.recordAttempt(
        targetId: nas,
        jobId: job1,
        filePath: '/m/L.fits',
        bytes: 0,
        now: pinT(12),
      ),
    );
    await pins(
      'recordAttempt negative bytes',
      () => dao.recordAttempt(
        targetId: nas,
        jobId: job1,
        filePath: '/m/L.fits',
        bytes: -1,
      ),
    );
    await pins(
      'recordAttempt second file',
      () => dao.recordAttempt(
        targetId: nas,
        jobId: job1,
        filePath: '/m/Ha.fits',
        bytes: 100,
        now: pinT(10),
      ),
    );
    await pins(
      'recordAttempt peer default now',
      () => dao.recordAttempt(
        targetId: peer,
        jobId: job2,
        filePath: '/m/report.html',
      ),
    );
    await pins.dump(db, 'delivery_journal', 'after attempts');

    await pins(
      'markDelivered',
      () => dao.markDelivered(
        targetId: nas,
        jobId: job1,
        filePath: '/m/L.fits',
        checksum: 'sha256:aa',
        bytes: 0,
        now: pinT(13),
      ),
    );
    await pins(
      'recordAttempt on delivered untouched',
      () => dao.recordAttempt(
        targetId: nas,
        jobId: job1,
        filePath: '/m/L.fits',
        bytes: 9,
        now: pinT(14),
      ),
    );
    await pins(
      'markFailed on delivered untouched',
      () => dao.markFailed(
        targetId: nas,
        jobId: job1,
        filePath: '/m/L.fits',
        error: 'late',
        now: pinT(15),
      ),
    );
    await pins(
      'recordStillOwed on delivered untouched',
      () => dao.recordStillOwed(
        targetId: nas,
        jobId: job1,
        filePath: '/m/L.fits',
        reason: 'stop',
        now: pinT(15),
      ),
    );
    await pins(
      'markRetrying Ha',
      () => dao.markRetrying(
        targetId: nas,
        jobId: job1,
        filePath: '/m/Ha.fits',
        error: 'share offline',
        now: pinT(16),
      ),
    );
    await pins(
      'markFailed Ha',
      () => dao.markFailed(
        targetId: nas,
        jobId: job1,
        filePath: '/m/Ha.fits',
        error: 'budget spent',
        now: pinT(17),
      ),
    );
    await pins(
      'markRetrying missing',
      () => dao.markRetrying(
        targetId: nas,
        jobId: job2,
        filePath: '/nope',
        error: 'x',
      ),
    );
    await pins(
      'markDelivered missing',
      () => dao.markDelivered(targetId: nas, jobId: job2, filePath: '/nope'),
    );
    await pins(
      'recordStillOwed new',
      () => dao.recordStillOwed(
        targetId: nas,
        jobId: job2,
        filePath: '/m/OIII.fits',
        reason: 'operator stopped the pass',
        bytes: 55,
        now: pinT(18),
      ),
    );
    await pins(
      'recordStillOwed existing failed',
      () => dao.recordStillOwed(
        targetId: nas,
        jobId: job1,
        filePath: '/m/Ha.fits',
        reason: 'stopped again',
        now: pinT(19),
      ),
    );
    await pins(
      'recordStillOwed negative',
      () => dao.recordStillOwed(
        targetId: nas,
        jobId: job1,
        filePath: '/m/Ha.fits',
        reason: 'x',
        bytes: -3,
      ),
    );
    await pins(
      'markDelivered keeps checksum when null',
      () => dao.markDelivered(
        targetId: nas,
        jobId: job2,
        filePath: '/m/OIII.fits',
        bytes: 77,
        now: pinT(20),
      ),
    );
    await pins(
      'requeueForRetry delivered',
      () => dao.requeueForRetry(
        targetId: nas,
        jobId: job1,
        filePath: '/m/L.fits',
        now: pinT(21),
      ),
    );
    await pins(
      'requeueForRetry missing',
      () => dao.requeueForRetry(targetId: peer, jobId: job1, filePath: '/x'),
    );
    await pins(
      'markRetrying peer default now',
      () => dao.markRetrying(
        targetId: peer,
        jobId: job2,
        filePath: '/m/report.html',
        error: 'not pulled yet',
      ),
    );
    await pins.dump(db, 'delivery_journal', 'after outcomes');

    await pins('listForJob job1', () => dao.listForJob(job1));
    await pins('listForJob job2', () => dao.listForJob(job2));
    await pins('listForTarget nas', () => dao.listForTarget(nas));
    await pins('listForTarget peer', () => dao.listForTarget(peer));
    await pins('listPendingRetry', dao.listPendingRetry);
    pins.verify();
  });

  test('RecipesDao results are pinned', () async {
    final pins = PinRecorder('recipes_dao', encode: _encode);
    final dao = RecipesDao(db);
    final master = await db.customInsert(
      'INSERT INTO integrated_masters (name, created_at, updated_at) '
      "VALUES ('M31 L', 1740866400, 1740866400)",
    );

    await pins('empty getById', () => dao.getById(1));
    await pins('empty listForMaster', () => dao.listForMaster('/m.fits'));
    await pins('empty childrenOf', () => dao.childrenOf(1));
    await pins('empty chainToRoot', () => dao.chainToRoot(1));
    await pins('empty descendantsOf', () => dao.descendantsOf(1));
    await pins('empty draftNotesOf', () => dao.draftNotesOf(1));

    await pins(
      'create root',
      () => dao.create(
        targetId: seed.targets[0],
        sessionId: seed.sessions[0],
        masterId: master,
        baseMasterPath: '/m/M31_L.fits',
        name: 'Draft',
        stepsJson: '[{"op_id":"stretch"}]',
        draftNotes: const [
          RecipeDraftNote(
            opId: 'color_calibration',
            outcome: 'omitted',
            reason: 'mono master',
          ),
        ],
        createdAt: pinT(10),
      ),
    );
    await pins(
      'create second root tie',
      () => dao.create(
        baseMasterPath: '/m/M31_L.fits',
        createdBy: RecipeAuthor.user,
        schemaVersion: 2,
        createdAt: pinT(10),
        updatedAt: pinT(11),
      ),
    );
    await pins(
      'create other master default now',
      () => dao.create(baseMasterPath: '/m/other.fits'),
    );
    await pins(
      'create empty path',
      () => dao.create(baseMasterPath: ''),
    );
    await pins(
      'create schema 0',
      () => dao.create(baseMasterPath: '/m.fits', schemaVersion: 0),
    );
    await pins(
      'create half branch',
      () => dao.create(baseMasterPath: '/m.fits', parentRecipeId: 1),
    );
    await pins(
      'branchFrom 1 at 1',
      () => dao.branchFrom(
        parentRecipeId: 1,
        divergenceIndex: 1,
        name: 'Softer',
        createdAt: pinT(20),
      ),
    );
    await pins(
      'branchFrom 1 at 0 tie',
      () => dao.branchFrom(
        parentRecipeId: 1,
        divergenceIndex: 0,
        name: 'Fresh',
        stepsJson: '[]',
        createdBy: RecipeAuthor.autopilot,
        createdAt: pinT(20),
      ),
    );
    await pins(
      'branchFrom 4',
      () => dao.branchFrom(
        parentRecipeId: 4,
        divergenceIndex: 2,
        name: 'Deeper',
        createdAt: pinT(30),
      ),
    );
    await pins(
      'branchFrom missing',
      () => dao.branchFrom(parentRecipeId: 99, divergenceIndex: 0, name: 'x'),
    );
    await pins(
      'branchFrom negative',
      () => dao.branchFrom(parentRecipeId: 1, divergenceIndex: -1, name: 'x'),
    );
    await pins.dump(db, 'recipes', 'after create');

    await pins('getById 4', () => dao.getById(4));
    await pins('listForMaster', () => dao.listForMaster('/m/M31_L.fits'));
    await pins('listForSession', () => dao.listForSession(seed.sessions[0]));
    await pins('listForTarget', () => dao.listForTarget(seed.targets[0]));
    await pins('listForTarget none', () => dao.listForTarget(seed.targets[2]));
    await pins('childrenOf 1', () => dao.childrenOf(1));
    await pins('chainToRoot 6', () => dao.chainToRoot(6));
    await pins('descendantsOf 1', () => dao.descendantsOf(1));
    await pins('draftNotesOf 1', () => dao.draftNotesOf(1));
    await pins('draftNotesOf 2', () => dao.draftNotesOf(2));

    await pins(
      'updateSteps',
      () => dao.updateSteps(2, '[{"op_id":"crop"}]', now: pinT(40)),
    );
    await pins(
      'updateSteps version',
      () => dao.updateSteps(2, '[]', schemaVersion: 3, now: pinT(41)),
    );
    await pins(
      'updateSteps bad version',
      () => dao.updateSteps(2, '[]', schemaVersion: 0),
    );
    await pins('updateSteps missing', () => dao.updateSteps(99, '[]'));
    await pins(
      'setDraftNotes',
      () => dao.setDraftNotes(2, const [
        RecipeDraftNote(opId: 'a', outcome: 'included', reason: 'r'),
        RecipeDraftNote(opId: 'b', outcome: 'retried', reason: 's'),
      ], now: pinT(42)),
    );
    await pins('setDraftNotes missing', () => dao.setDraftNotes(99, const []));
    await pins('rename', () => dao.rename(3, 'Renamed', now: pinT(43)));
    await pins('rename default now', () => dao.rename(5, 'Fresh 2'));
    await pins.dump(db, 'recipes', 'after updates');
    await pins('draftNotesOf 2 after set', () => dao.draftNotesOf(2));

    await pins('deleteRecipe with children', () => dao.deleteRecipe(1));
    await pins('deleteRecipe leaf', () => dao.deleteRecipe(5));
    await pins('deleteRecipe missing', () => dao.deleteRecipe(5));
    await pins('deleteRecipeSubtree 1', () => dao.deleteRecipeSubtree(1));
    await pins.dump(db, 'recipes', 'after delete');

    await db.customStatement(
      "UPDATE recipes SET draft_notes_json = 'nope' WHERE id = 2",
    );
    await pins('draftNotesOf corrupt', () => dao.draftNotesOf(2));
    await db.customStatement(
      "UPDATE recipes SET draft_notes_json = '[{\"opId\":1}]' WHERE id = 3",
    );
    await pins('draftNotesOf bad entry', () => dao.draftNotesOf(3));
    await db.customStatement('PRAGMA foreign_keys = OFF');
    final a = await dao.create(baseMasterPath: '/c.fits', createdAt: pinT(50));
    final b = await dao.create(
      baseMasterPath: '/c.fits',
      parentRecipeId: a,
      divergenceIndex: 0,
      createdAt: pinT(51),
    );
    await db.customStatement(
      'UPDATE recipes SET parent_recipe_id = $b, divergence_index = 0 '
      'WHERE id = $a',
    );
    await pins('chainToRoot cycle', () => dao.chainToRoot(a));
    await pins('descendantsOf cycle', () => dao.descendantsOf(a));
    await db.customStatement(
      'UPDATE recipes SET parent_recipe_id = 999 WHERE id = $a',
    );
    await pins('chainToRoot dangling parent', () => dao.chainToRoot(a));
    pins.verify();
  });
}
