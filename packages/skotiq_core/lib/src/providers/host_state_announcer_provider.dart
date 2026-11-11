import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/backend/host_mutation_event.dart';
import '../backend/remote_host.dart';
import 'backend_provider.dart';
import 'framing_provider.dart';
import 'host_mutation_event_provider.dart';

/// On the machine that owns the hardware, announce to linked clients the
/// shared state that changes in a provider rather than through a REST handler,
/// so a change made on the host's own screen reaches them at once.
///
/// Announced from the state itself, a change is announced once whichever
/// path made it: the host's screen, a REST handler or a script. Only linked
/// clients are told; this app's own screens already watch the state.
///
/// Today this is the framing target. Profile activation is announced by
/// [EquipmentProfilesNotifier], and settings rows by the settings DAO.
final hostStateAnnouncerProvider = Provider<void>((ref) {
  ref.listen<FramingTarget?>(framingProvider.select((state) => state.target), (
    previous,
    next,
  ) {
    if (next == null || identical(previous, next)) return;
    if (ref.read(backendProvider).remoteHost != null) return;
    ref
        .read(hostMutationEventHubProvider)
        .publishRemoteOnly(
          entityType: HostMutationEntity.framing,
          action: HostMutationAction.updated,
          extra: {
            'ra': next.raHours,
            'dec': next.decDegrees,
            'name': next.name,
          },
        );
  });
});
