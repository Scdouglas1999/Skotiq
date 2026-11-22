import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../../services/sequence_action_service.dart';

typedef SmartNightProviderRead = T Function<T>(ProviderListenable<T> provider);

/// Launches an accepted Smart Night plan.
///
/// Keep this outside the dialog so the launch contract is testable: the
/// generated sequence is loaded into the editor, [confirm] (the pre-flight
/// checks) is asked, the executor is started, and the draft is marked started
/// only after the executor accepts the run.
class SmartNightPlanLauncher {
  const SmartNightPlanLauncher();

  Future<void> launch({
    required SmartNightProviderRead read,
    required SmartNightPlan plan,
    String? draftId,
    Future<bool> Function()? confirm,
  }) async {
    await read(sequenceActionServiceProvider).startOwnedPlan(
      plan.sequence,
      ActivePlanOwner.smartNight,
      confirm: confirm,
    );

    if (draftId != null) {
      await read(smartNightDraftServiceProvider).markStarted(draftId);
    }
  }
}
