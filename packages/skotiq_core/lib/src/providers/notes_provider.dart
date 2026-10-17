import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../models/notes/journal_note.dart';
import '../services/notes_service.dart';
import '../services/sequence_diff_service.dart';
import '../utils/resilient_poll_stream.dart';
import 'backend_provider.dart';
import 'database_provider.dart';

/// Riverpod surface for per-target / per-run notes
/// and the structural sequence diff.
///
/// The service-layer types are exposed through thin providers so the UI never
/// reaches into the raw Drift connection directly. The list providers are
/// [StreamProvider]s fed by the service's broadcast controller, which pumps a
/// fresh snapshot on every mutation — including writes from another surface,
/// so a note added on the target card re-renders the history dialog.

final notesServiceProvider = Provider<NotesService>((ref) {
  final database = ref.watch(databaseProvider);
  final service = NotesService(database);
  ref.onDispose(() {
    // Fire-and-forget close — the broadcaster has no IO side-effects.
    service.dispose();
  });
  return service;
});

/// Host-authoritative mutation surface for journal notes.
///
/// Read providers already poll the imaging host in remote mode. Routing edits
/// through this repository keeps create/update/delete on that same authority
/// instead of reporting success after writing to the controller's unused
/// local database.
class NotesRepository {
  final NotesService? _local;
  final NetworkBackend? _remote;
  final void Function()? _afterRemoteMutation;

  NotesRepository.local(NotesService local)
    : _local = local,
      _remote = null,
      _afterRemoteMutation = null;

  NotesRepository.remote(
    NetworkBackend remote, {
    required void Function() afterMutation,
  }) : _local = null,
       _remote = remote,
       _afterRemoteMutation = afterMutation;

  bool get isRemote => _remote != null;

  Future<JournalNote> addNote({
    required String targetId,
    int? sequenceRunId,
    required String body,
    String? title,
    List<String> tags = const <String>[],
    List<String> attachments = const <String>[],
    String? sentiment,
  }) async {
    final remote = _remote;
    if (remote == null) {
      return _local!.addNote(
        targetId: targetId,
        sequenceRunId: sequenceRunId,
        body: body,
        title: title,
        tags: tags,
        attachments: attachments,
        sentiment: sentiment,
      );
    }
    final note = await remote.createJournalNote(
      targetId: targetId,
      sequenceRunId: sequenceRunId,
      body: body,
      title: title,
      tags: tags,
      attachments: attachments,
      sentiment: sentiment,
    );
    _afterRemoteMutation!();
    return _noteFromRemote(note);
  }

  Future<JournalNote> updateNote(
    String id, {
    String? body,
    String? title,
    List<String>? tags,
    List<String>? attachments,
    String? sentiment,
    bool clearTitle = false,
    bool clearSentiment = false,
  }) async {
    final remote = _remote;
    if (remote == null) {
      return _local!.updateNote(
        id,
        body: body,
        title: title,
        tags: tags,
        attachments: attachments,
        sentiment: sentiment,
        clearTitle: clearTitle,
        clearSentiment: clearSentiment,
      );
    }
    final note = await remote.updateJournalNote(
      id,
      body: body,
      title: title,
      tags: tags,
      attachments: attachments,
      sentiment: sentiment,
      clearTitle: clearTitle,
      clearSentiment: clearSentiment,
    );
    _afterRemoteMutation!();
    return _noteFromRemote(note);
  }

  Future<int> deleteNote(String id) async {
    final remote = _remote;
    if (remote == null) return _local!.deleteNote(id);
    await remote.deleteJournalNote(id);
    _afterRemoteMutation!();
    return 1;
  }
}

final notesRepositoryProvider = Provider<NotesRepository>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return NotesRepository.remote(
      backend,
      afterMutation: () {
        ref.invalidate(notesForTargetProvider);
        ref.invalidate(notesForRunProvider);
        ref.invalidate(allNotesProvider);
      },
    );
  }
  return NotesRepository.local(ref.watch(notesServiceProvider));
});

/// Live notes for a target. Family-keyed by the logical target id
/// string (catalog id or display name).
///
/// On a remote client (`NetworkBackend`) the journal lives only on the
/// master; the slave's local `notes_journal` table is never populated. We
/// poll the host's `GET /api/db/notes?targetId=` and map each
/// [RemoteJournalNote] onto [JournalNote]. The local `NotesService` path is
/// unchanged for the host backend.
final notesForTargetProvider = StreamProvider.family<List<JournalNote>, String>(
  (ref, targetId) {
    final backend = ref.watch(backendProvider);
    if (backend is NetworkBackend) {
      return _pollRemoteNotes(backend, targetId: targetId);
    }
    final service = ref.watch(notesServiceProvider);
    return service.watchTargetNotes(targetId);
  },
);

/// Live notes for a specific sequence run row id.
final notesForRunProvider = StreamProvider.family<List<JournalNote>, int>((
  ref,
  runId,
) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteNotes(backend, runId: runId);
  }
  final service = ref.watch(notesServiceProvider);
  return service.watchRunNotes(runId);
});

/// Live stream of every note (for global search / debug views).
final allNotesProvider = StreamProvider<List<JournalNote>>((ref) {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return _pollRemoteNotes(backend);
  }
  final service = ref.watch(notesServiceProvider);
  return service.watchAllNotes();
});

/// Polls the host's journal notes, emitting only on change (mirrors the
/// `_pollRemote` change-guard in `database_provider.dart`). [targetId] /
/// [runId] scope the poll for the family variants.
Stream<List<JournalNote>> _pollRemoteNotes(
  NetworkBackend backend, {
  String? targetId,
  int? runId,
  Duration interval = const Duration(seconds: 10),
}) => resilientDistinctPoll(
  fetch: () => _fetchRemoteNotes(backend, targetId: targetId, runId: runId),
  unchanged: listEquals,
  interval: interval,
);

Future<List<JournalNote>> _fetchRemoteNotes(
  NetworkBackend backend, {
  String? targetId,
  int? runId,
}) async {
  final page = await backend.fetchJournalNotes(
    targetId: targetId,
    runId: runId,
  );
  final mapped = page.items.map(_noteFromRemote).toList()
    // Host serves created_at desc; keep newest-first.
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return mapped;
}

JournalNote _noteFromRemote(RemoteJournalNote row) {
  return JournalNote(
    id: row.id,
    targetId: row.targetId,
    sequenceRunId: row.sequenceRunId,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    title: row.title,
    body: row.body,
    tags: row.tags,
    attachments: row.attachments,
    sentiment: row.sentiment,
  );
}

/// Singleton diff engine. Stateless, no setup cost.
final sequenceDiffServiceProvider = Provider<SequenceDiffService>(
  (ref) => const SequenceDiffService(),
);

/// Settings key for the "prompt for notes after run" preference.
const String kPromptForNotesAfterRunKey = 'notes.prompt_after_run';

/// Whether the auto-prompt note dialog should appear after a run
/// completes. Defaults to `true` when the setting has never been
/// written (the journal feature is opt-out, not opt-in: the report
/// is more useful when the user is in the habit of dropping a quick
/// note at the end of every run).
final promptForNotesAfterRunProvider = StreamProvider<bool>((ref) {
  final dao = ref.watch(settingsDaoProvider);
  return dao.watchSetting(kPromptForNotesAfterRunKey).map((raw) {
    if (raw == null) return true;
    return raw.toLowerCase() == 'true';
  });
});

/// Mutator for the auto-prompt preference.
final notesPromptToggleProvider = Provider<Future<void> Function(bool)>((ref) {
  final dao = ref.watch(settingsDaoProvider);
  return (bool enabled) async {
    await dao.setSetting(kPromptForNotesAfterRunKey, enabled.toString());
  };
});
