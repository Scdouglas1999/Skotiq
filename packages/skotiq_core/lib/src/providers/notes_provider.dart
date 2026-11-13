import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/notes/journal_note.dart';
import '../services/notes_service.dart';
import '../services/sequence_diff_service.dart';
import '../backend/roles/host_data/notes_journal.dart';
import 'host_role.dart';
import 'database_provider.dart';
import 'settings_provider.dart'
    show SmartNightSettingsSection, appSettingsProvider;

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

/// The notes journal of whichever machine is the imaging host.
final notesJournalProvider = hostRoleProvider<NotesJournal>(
  here: (ref) => ref.watch(notesServiceProvider),
  linked: (ref, host) => host.notesJournal,
);

/// Live notes for a target, keyed by the logical target id (catalog id or
/// display name).
final notesForTargetProvider = StreamProvider.family<List<JournalNote>, String>(
  (ref, targetId) => ref.watch(notesJournalProvider).watchTargetNotes(targetId),
);

/// Live notes for a sequence run row id.
final notesForRunProvider = StreamProvider.family<List<JournalNote>, int>(
  (ref, runId) => ref.watch(notesJournalProvider).watchRunNotes(runId),
);

/// Every note, for the global search.
final allNotesProvider = StreamProvider<List<JournalNote>>(
  (ref) => ref.watch(notesJournalProvider).watchAllNotes(),
);

/// Singleton diff engine. Stateless, no setup cost.
final sequenceDiffServiceProvider = Provider<SequenceDiffService>(
  (ref) => const SequenceDiffService(),
);

/// Whether the auto-prompt note dialog should appear after a run completes
/// ([AppSettingsState.promptForNotesAfterRun]).
final promptForNotesAfterRunProvider = FutureProvider<bool>((ref) async {
  final settings = await ref.watch(appSettingsProvider.future);
  return settings.promptForNotesAfterRun;
});

/// Mutator for the auto-prompt preference.
final notesPromptToggleProvider = Provider<Future<void> Function(bool)>((ref) {
  return (bool enabled) =>
      ref.read(appSettingsProvider.notifier).setPromptForNotesAfterRun(enabled);
});
