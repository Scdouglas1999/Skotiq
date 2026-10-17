import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/session_handoff_service.dart';
import 'database_provider.dart';
import 'sequence_provider.dart';
import 'settings_provider.dart';

/// Service provider for SessionHandoffService.
///
/// Wires the DAOs so the service can perform multi-night
/// carry-over detection. The original device-to-device handoff API
/// (`exportBundle` / `describe`) still works without DAOs because the
/// constructor parameters are optional.
final sessionHandoffServiceProvider = Provider<SessionHandoffService>((ref) {
  return SessionHandoffService(
    sessionsDao: ref.watch(sessionsDaoProvider),
    imagesDao: ref.watch(imagesDaoProvider),
    targetsDao: ref.watch(targetsDaoProvider),
  );
});

/// Carry-over detection for the current in-editor sequence.
///
/// Auto-invalidates when the sequence model changes (i.e. a target is
/// added/removed). Returns an empty list when no recent prior sessions match
/// the target list or the sequence is empty. Data-source failures propagate:
/// treating "history could not be read" as "there is no history" can start a
/// multi-night budget at zero and recapture hours the user already banked.
/// Pre-flight offers an explicit start-without-history choice; direct executor
/// starts fail before hardware launch.
final sessionCarryOverProvider =
    FutureProvider.autoDispose<List<SessionCarryOver>>((ref) async {
      final sequence = ref.watch(currentSequenceProvider);
      if (sequence == null) return const <SessionCarryOver>[];
      final service = ref.watch(sessionHandoffServiceProvider);
      final libraryTargets = await ref.watch(allDbTargetsProvider.future);
      final capturedImages = await ref.watch(allDbImagesProvider.future);
      final sessions = await ref.watch(allSessionsProvider.future);
      return service.detectCarryOver(
        sequence: sequence,
        libraryTargets: libraryTargets,
        capturedImages: capturedImages,
        sessions: sessions,
      );
    });

/// Controls whether the carry-over pre-flight dialog auto-opens.
///
/// Resolves the authoritative [AppSettingsState.sessionHandoffAutoPrompt]
/// toggle for pre-flight.
///
/// Loading or a settings-store failure must remain loading/error: a `true`
/// default would open the carry-over prompt on a Start pressed during startup
/// even for an operator who disabled it.
final sessionHandoffAutoPromptProvider = FutureProvider<bool>((ref) async {
  final settings = await ref.watch(appSettingsProvider.future);
  return settings.sessionHandoffAutoPrompt;
});

/// One-shot operator authorization to launch even when prior-session history
/// is unavailable.
///
/// Only the pre-flight confirmation dialog sets this. The executor consumes
/// and clears it while seeding integration carry-over, so an unrelated later
/// start cannot inherit a stale "ignore history" choice.
final sessionHandoffIgnoreUnavailableOnceProvider = StateProvider<bool>(
  (ref) => false,
);

/// Operator's last decision for a given target id. Pre-flight
/// uses this to avoid re-prompting on the same sequence after the
/// user has chosen Restart / Continue New (Resume can be revoked by
/// opening the banner from the menu).
///
/// Keyed by `(sequenceDatabaseId, targetId)` so independent sequences
/// for the same target don't share state.
final sessionHandoffDecisionProvider =
    StateProvider.family<
      SessionHandoffDecision?,
      ({int? sequenceId, int targetId})
    >((ref, key) => null);
