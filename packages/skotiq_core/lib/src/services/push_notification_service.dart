import 'dart:async';

import '../models/backend/event_types.dart';

/// Priority of a phone push. A wire value: paired phones and the cloud push
/// relay read it by name, so it is assigned per category in
/// `NotificationPresentation` and never derived from a severity.
enum PushNotificationPriority {
  /// Low priority - informational events
  low,

  /// Normal priority - standard completion events
  normal,

  /// High priority - errors and safety events requiring attention
  high,

  /// Critical priority - immediate attention required (weather unsafe, guiding lost)
  critical,
}

/// A push notification ready to be sent to connected mobile devices
class PushNotification {
  final String title;
  final String body;
  final PushNotificationPriority priority;
  final String eventType;
  final EventCategory category;
  final DateTime timestamp;

  /// Where a tap on this push should land, in the phone's own
  /// `type[:arg]` payload convention (for example
  /// `darkroom_draft:job-7-master-3`).
  ///
  /// Null for every push whose event type alone says where to go — the phone
  /// already maps `push:<eventType>` to a screen. It is non-null only when the
  /// destination depends on an id the event type cannot carry, which is why it
  /// travels as an opaque payload rather than a route: the host does not own
  /// the phone's route table and must not guess at its shape.
  final String? deepLink;

  const PushNotification({
    required this.title,
    required this.body,
    required this.priority,
    required this.eventType,
    required this.category,
    required this.timestamp,
    this.deepLink,
  });

  Map<String, dynamic> toJson() => {
    'type': 'push_notification',
    'title': title,
    'body': body,
    'priority': priority.name,
    'eventType': eventType,
    'category': category.name,
    'timestamp': timestamp.millisecondsSinceEpoch,
    // Omitted rather than sent as null so an older phone build, which reads
    // the map key-by-key, sees exactly the shape it saw before.
    if (deepLink != null) 'deepLink': deepLink,
  };
}

/// The per-event switches of [PushNotificationConfig].
enum PushToggle {
  sequenceCompleted,
  sequenceFailed,
  meridianFlip,
  weatherUnsafe,
  guidingLost,
  exposureFailed,
  autofocusFailed,
  equipmentDisconnected,
}

/// Which events reach paired phones.
///
/// `enabled` is the master gate that suppresses every phone push; the
/// per-event switches are read by `SystemPushTransport` through [allows].
class PushNotificationConfig {
  final bool enabled;
  final bool notifySequenceCompleted;
  final bool notifySequenceFailed;
  final bool notifyMeridianFlip;
  final bool notifyWeatherUnsafe;
  final bool notifyGuidingLost;
  final bool notifyExposureFailed;
  final bool notifyAutofocusFailed;
  final bool notifyEquipmentDisconnected;

  const PushNotificationConfig({
    this.enabled = true,
    this.notifySequenceCompleted = true,
    this.notifySequenceFailed = true,
    this.notifyMeridianFlip = true,
    this.notifyWeatherUnsafe = true,
    this.notifyGuidingLost = true,
    this.notifyExposureFailed = true,
    this.notifyAutofocusFailed = true,
    this.notifyEquipmentDisconnected = false,
  });

  bool allows(PushToggle toggle) => switch (toggle) {
    PushToggle.sequenceCompleted => notifySequenceCompleted,
    PushToggle.sequenceFailed => notifySequenceFailed,
    PushToggle.meridianFlip => notifyMeridianFlip,
    PushToggle.weatherUnsafe => notifyWeatherUnsafe,
    PushToggle.guidingLost => notifyGuidingLost,
    PushToggle.exposureFailed => notifyExposureFailed,
    PushToggle.autofocusFailed => notifyAutofocusFailed,
    PushToggle.equipmentDisconnected => notifyEquipmentDisconnected,
  };

  PushNotificationConfig copyWith({
    bool? enabled,
    bool? notifySequenceCompleted,
    bool? notifySequenceFailed,
    bool? notifyMeridianFlip,
    bool? notifyWeatherUnsafe,
    bool? notifyGuidingLost,
    bool? notifyExposureFailed,
    bool? notifyAutofocusFailed,
    bool? notifyEquipmentDisconnected,
  }) {
    return PushNotificationConfig(
      enabled: enabled ?? this.enabled,
      notifySequenceCompleted:
          notifySequenceCompleted ?? this.notifySequenceCompleted,
      notifySequenceFailed: notifySequenceFailed ?? this.notifySequenceFailed,
      notifyMeridianFlip: notifyMeridianFlip ?? this.notifyMeridianFlip,
      notifyWeatherUnsafe: notifyWeatherUnsafe ?? this.notifyWeatherUnsafe,
      notifyGuidingLost: notifyGuidingLost ?? this.notifyGuidingLost,
      notifyExposureFailed: notifyExposureFailed ?? this.notifyExposureFailed,
      notifyAutofocusFailed:
          notifyAutofocusFailed ?? this.notifyAutofocusFailed,
      notifyEquipmentDisconnected:
          notifyEquipmentDisconnected ?? this.notifyEquipmentDisconnected,
    );
  }
}

/// Mobile-push output broadcaster.
///
/// This service owns no event-stream subscription and classifies nothing:
/// [NotificationRouter] is the single producer of mobile pushes, and its
/// [SystemPushTransport] calls [enqueue] for every systemPush-routed
/// notification. The job here is to broadcast those [PushNotification]s onto
/// its stream, which the embedded web server fans out to paired phones over
/// WebSocket.
///
/// The [PushNotificationConfig] lives here because it is the systemPush
/// feed's config: [SystemPushTransport] reads it (via [config]) to apply the
/// per-event toggles and the master `enabled` gate before enqueuing. Keeping
/// it on the broadcaster keeps one config store for the one feed.
class PushNotificationService {
  PushNotificationConfig _config;

  final StreamController<PushNotification> _notificationController =
      StreamController<PushNotification>.broadcast();

  PushNotificationService({
    PushNotificationConfig config = const PushNotificationConfig(),
  }) : _config = config;

  /// Stream of push notifications to broadcast to mobile clients
  Stream<PushNotification> get notifications => _notificationController.stream;

  PushNotificationConfig get config => _config;

  /// Whether anything is subscribed to [notifications]. The remote access
  /// server is the subscriber; with it off, a push goes nowhere.
  bool get hasListener => _notificationController.hasListener;

  /// Update configuration. No subscription is started/stopped any more — the
  /// router is the sole producer — so this simply swaps the gating config the
  /// transport reads on its next enqueue.
  void updateConfig(PushNotificationConfig config) {
    _config = config;
  }

  /// Broadcast a single push to paired phones.
  ///
  /// Called only by `SystemPushTransport`. The master `enabled` gate is
  /// enforced here so that disabling push swallows every phone push.
  void enqueue(PushNotification notification) {
    if (!_config.enabled) return;
    _notificationController.add(notification);
  }

  /// Emit a test push notification. Broadcasting onto the stream is the only
  /// step this service owns; end-to-end delivery to a paired phone cannot be
  /// confirmed from here.
  Future<void> sendTestNotification() async {
    if (!_config.enabled) {
      throw StateError('Push notifications are disabled.');
    }
    if (!_notificationController.hasListener) {
      throw StateError(
        'No push transport is listening. Start remote access before testing.',
      );
    }
    _notificationController.add(
      PushNotification(
        title: 'Test Notification',
        body: 'Skotiq push pipeline test.',
        priority: PushNotificationPriority.normal,
        eventType: 'Test',
        category: EventCategory.system,
        timestamp: DateTime.now(),
      ),
    );
  }

  void dispose() {
    _notificationController.close();
  }
}
