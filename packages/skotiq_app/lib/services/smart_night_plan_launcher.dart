import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

typedef SmartNightProviderRead = T Function<T>(ProviderListenable<T> provider);

/// Launches an accepted Smart Night plan.
///
/// Keep this outside the dialog so the launch contract is testable: the
/// generated sequence is loaded into the editor, the executor is started, and
/// the draft is marked started only after the executor accepts the run.
class SmartNightPlanLauncher {
  const SmartNightPlanLauncher();

  Future<void> launch({
    required SmartNightProviderRead read,
    required SmartNightPlan plan,
    String? draftId,
  }) async {
    // Hand the editor slot to the Smart Night owner rather than discarding the
    // operator's unsaved work: takeOwnership stashes the manual sequence and
    // flips the owner, so stopping the run restores it.
    read(currentSequenceProvider.notifier).takeOwnership(
      plan.sequence,
      ActivePlanOwner.smartNight,
    );

    await read(sequenceExecutorProvider).start();

    if (draftId != null) {
      await SmartNightDraftService(
        settingsDao: read(settingsDaoProvider),
      ).markStarted(draftId);
    }
  }
}
