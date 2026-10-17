import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/services/notes_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NotesService', () {
    late SkotiqDatabase db;
    late NotesService service;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      service = NotesService(db);
    });

    tearDown(() async {
      await service.dispose();
      await db.close();
    });

    test('addNote persists a note and returns it with a UUID', () async {
      final note = await service.addNote(
        targetId: 'M31',
        body: 'Seeing rough but improved after 2 AM.',
        title: 'Tough start',
        tags: ['seeing', 'guiding'],
      );
      expect(note.id, isNotEmpty);
      expect(note.targetId, 'M31');
      expect(note.title, 'Tough start');
      expect(note.tags, ['seeing', 'guiding']);
      expect(note.body, contains('Seeing rough'));
      expect(note.sentiment, isNull);

      final reloaded = await service.getNoteById(note.id);
      expect(reloaded, isNotNull);
      expect(reloaded!.body, note.body);
      expect(reloaded.tags, note.tags);
    });

    test('addNote rejects empty target id', () async {
      expect(
        () => service.addNote(targetId: '', body: 'x'),
        throwsArgumentError,
      );
    });

    test('notesForTarget returns notes scoped to that target', () async {
      await service.addNote(targetId: 'M31', body: 'first');
      await service.addNote(targetId: 'M31', body: 'second');
      await service.addNote(targetId: 'NGC7000', body: 'unrelated');

      final m31Notes = await service.notesForTarget('M31');
      expect(m31Notes.length, 2);
      // Newest first by created_at.
      expect(
        m31Notes.first.createdAt.isAfter(
          m31Notes.last.createdAt.subtract(const Duration(seconds: 1)),
        ),
        isTrue,
      );

      final ngcNotes = await service.notesForTarget('NGC7000');
      expect(ngcNotes.length, 1);
      expect(ngcNotes.single.body, 'unrelated');
    });

    test('notesForRun filters by sequence_run_id', () async {
      await service.addNote(targetId: 'M31', sequenceRunId: 7, body: 'r7');
      await service.addNote(targetId: 'M31', sequenceRunId: 7, body: 'r7-2');
      await service.addNote(targetId: 'M31', sequenceRunId: 9, body: 'r9');
      await service.addNote(targetId: 'M31', body: 'no run');

      final r7 = await service.notesForRun(7);
      expect(r7.length, 2);
      expect(r7.map((n) => n.body).toSet(), {'r7', 'r7-2'});
      final r9 = await service.notesForRun(9);
      expect(r9.length, 1);
      expect(r9.single.body, 'r9');
    });

    test('updateNote replaces body, title, tags, sentiment', () async {
      final note = await service.addNote(
        targetId: 'M31',
        body: 'before',
        title: 'old title',
        tags: ['a'],
      );
      // Give the update a different timestamp.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final updated = await service.updateNote(
        note.id,
        body: 'after',
        title: 'new title',
        tags: ['a', 'b'],
        sentiment: '😊',
      );
      expect(updated.body, 'after');
      expect(updated.title, 'new title');
      expect(updated.tags, ['a', 'b']);
      expect(updated.sentiment, '😊');
      expect(updated.updatedAt.isAfter(note.updatedAt), isTrue);

      final reloaded = await service.getNoteById(note.id);
      expect(reloaded!.body, 'after');
      expect(reloaded.sentiment, '😊');
    });

    test('updateNote throws when id is unknown', () async {
      expect(
        () => service.updateNote('does-not-exist', body: 'x'),
        throwsStateError,
      );
    });

    test('deleteNote removes the row', () async {
      final note = await service.addNote(targetId: 'M31', body: 'rip');
      expect(await service.getNoteById(note.id), isNotNull);
      final affected = await service.deleteNote(note.id);
      expect(affected, 1);
      expect(await service.getNoteById(note.id), isNull);
    });

    test('deleteNote on unknown id is a no-op', () async {
      final affected = await service.deleteNote('nope');
      expect(affected, 0);
    });

    test('searchNotes matches by query text', () async {
      await service.addNote(
        targetId: 'M31',
        body: 'Polar alignment was rough.',
      );
      await service.addNote(
        targetId: 'M42',
        body: 'Guiding was smooth all night.',
      );
      await service.addNote(targetId: 'NGC7000', body: 'no match here');

      final guidingResults = await service.searchNotes(query: 'guiding');
      expect(guidingResults.length, 1);
      expect(guidingResults.single.targetId, 'M42');

      final caseInsensitive = await service.searchNotes(query: 'POLAR');
      expect(caseInsensitive.length, 1);
      expect(caseInsensitive.single.targetId, 'M31');
    });

    test('searchNotes filters by tags', () async {
      await service.addNote(targetId: 'M31', body: 'a', tags: ['seeing']);
      await service.addNote(targetId: 'M31', body: 'b', tags: ['guiding']);
      await service.addNote(
        targetId: 'M31',
        body: 'c',
        tags: ['seeing', 'guiding'],
      );

      final seeing = await service.searchNotes(tags: ['seeing']);
      expect(seeing.length, 2);
      final guiding = await service.searchNotes(tags: ['guiding']);
      expect(guiding.length, 2);
      // Tag containment must be exact — "see" must NOT match "seeing".
      final partial = await service.searchNotes(tags: ['see']);
      expect(partial, isEmpty);
    });

    test('watchTargetNotes emits initial + on every mutation', () async {
      // `take(3)` makes the stream close itself once it sees the
      // expected snapshots so the async generator exits the
      // `await for` cleanly without us having to coordinate the
      // dispose race in tearDown.
      final emissions = <int>[];
      final done = Completer<void>();
      late StreamSubscription<List<dynamic>> sub;
      sub = service.watchTargetNotes('M31').listen((notes) async {
        emissions.add(notes.length);
        if (emissions.length == 3) {
          await sub.cancel();
          if (!done.isCompleted) done.complete();
        }
      });
      // Pump the event loop so the async-generator yields the initial
      // snapshot before we mutate.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await service.addNote(targetId: 'M31', body: 'one');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await service.addNote(targetId: 'M31', body: 'two');
      await done.future.timeout(const Duration(seconds: 5));
      expect(emissions, containsAllInOrder(<int>[0, 1, 2]));
    });
  });

  group('buildAutoPromptNoteBody', () {
    test('includes frame counts, autofocus, and triggers when set', () {
      final body = buildAutoPromptNoteBody(
        sequenceName: 'M31 Lights',
        wallClock: const Duration(hours: 6, minutes: 12),
        framesCaptured: 47,
        framesRejected: 12,
        triggerFires: 3,
        autofocusRuns: 4,
        meridianFlips: 1,
        triggerBreakdown: {'HFR drift': 2, 'Cloud arriving': 1},
      );
      expect(body, contains('M31 Lights'));
      expect(body, contains('6h 12m'));
      expect(body, contains('47'));
      expect(body, contains('12 rejected'));
      expect(body, contains('Autofocus runs: 4'));
      expect(body, contains('Meridian flips: 1'));
      expect(body, contains('HFR drift x2'));
      expect(body, contains('Cloud arriving x1'));
    });

    test('omits zero-valued counters', () {
      final body = buildAutoPromptNoteBody(
        sequenceName: 'M42',
        wallClock: const Duration(minutes: 15),
        framesCaptured: 8,
        framesRejected: 0,
        triggerFires: 0,
        autofocusRuns: 0,
        meridianFlips: 0,
      );
      expect(body, contains('8'));
      expect(body, isNot(contains('rejected')));
      expect(body, isNot(contains('Autofocus')));
      expect(body, isNot(contains('Meridian')));
      expect(body, isNot(contains('Triggers')));
    });
  });
}
