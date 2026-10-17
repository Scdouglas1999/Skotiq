import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/backend/event_types.dart';
import '../services/host_mutation_event_hub.dart';

/// Process-wide hub for host REST mutation events.
///
/// [HeadlessApiServer] wires [HostMutationEventHub.wsBroadcast] while the
/// embedded API server is running. Handlers publish through this provider so
/// tests can override the hub in a [ProviderContainer].
final hostMutationEventHubProvider = Provider<HostMutationEventHub>((ref) {
  final hub = HostMutationEventHub();
  ref.onDispose(hub.dispose);
  return hub;
});

/// Broadcast stream of host mutation events for local EventBus merge and sync.
final hostMutationEventStreamProvider = Provider<Stream<SkotiqEvent>>((
  ref,
) {
  return ref.watch(hostMutationEventHubProvider).stream;
});

/// Ref variant for shared UI after local host mutations.
void publishHostMutationFromRef(
  WidgetRef ref, {
  required String entityType,
  required String action,
  String? entityId,
  Map<String, dynamic> extra = const {},
  bool remoteOnly = false,
}) {
  final hub = ref.read(hostMutationEventHubProvider);
  if (remoteOnly) {
    hub.publishRemoteOnly(
      entityType: entityType,
      action: action,
      entityId: entityId,
      extra: extra,
    );
    return;
  }
  hub.publish(
    entityType: entityType,
    action: action,
    entityId: entityId,
    extra: extra,
  );
}

/// Container variant for headless API handlers.
void publishHostMutationFromContainer(
  ProviderContainer container, {
  required String entityType,
  required String action,
  String? entityId,
  Map<String, dynamic> extra = const {},
  bool remoteOnly = false,
}) {
  final hub = container.read(hostMutationEventHubProvider);
  if (remoteOnly) {
    hub.publishRemoteOnly(
      entityType: entityType,
      action: action,
      entityId: entityId,
      extra: extra,
    );
    return;
  }
  hub.publish(
    entityType: entityType,
    action: action,
    entityId: entityId,
    extra: extra,
  );
}
