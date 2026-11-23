import '../models/backend/event_types.dart';
import '../services/host_mutation_event_hub.dart';
import 'ui_notification_provider.dart';

const nativeEventsLostTitle = 'Rig updates stopped';

const nativeEventsLostMessage =
    'Skotiq stopped receiving events from its native engine, so device, '
    'guiding and sequence updates no longer reach this window or linked '
    'clients. Restart Skotiq to get them back.';

/// Tells the operator that the native event stream is gone: the event
/// history, the night log and every linked client get the notice through
/// [hub], and this window shows it.
void announceNativeEventsLost({
  required HostMutationEventHub hub,
  required UiNotificationNotifier notifications,
}) {
  hub.announce(
    SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: EventSeverity.error,
      category: EventCategory.system,
      eventType: 'Notification',
      data: const {
        'title': nativeEventsLostTitle,
        'message': nativeEventsLostMessage,
        'level': 'error',
      },
    ),
  );
  notifications.showError(
    nativeEventsLostMessage,
    title: nativeEventsLostTitle,
  );
}
