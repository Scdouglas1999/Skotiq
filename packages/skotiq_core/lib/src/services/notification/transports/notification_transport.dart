// Base interface every transport implements.
//
// Why an abstract class rather than a typedef function: each transport
// needs a stable identity (`kind`), a "is the config valid enough to
// send?" check (drives the UI grey-out and test-send button), and a
// shared async send entry point. Subclasses live in sibling files in
// `transports/`.

import '../../../models/backend/event_types.dart';
import '../../../models/notification/notification_categories.dart';

/// One rendered message on its way to the transports.
class NotificationMessage {
  final NotificationCategory category;
  final String title;
  final String body;

  /// The one severity scale every transport maps from (toast style, Pushover
  /// priority, embed color). Defaults to the category's own.
  final EventSeverity severity;

  /// `type[:arg]` tap payload. The phone push and the in-app banner act on
  /// it; an email has nowhere to navigate to.
  final String? deepLink;

  NotificationMessage({
    required this.category,
    required this.title,
    required this.body,
    EventSeverity? severity,
    this.deepLink,
  }) : severity = severity ?? category.defaultSeverity;
}

abstract class NotificationTransport {
  /// Which transport kind this implementation handles. Used by the
  /// router to pick the right instance for a given routing rule.
  NotificationTransportKind get kind;

  /// Human label shown in the settings UI.
  String get name;

  /// Whether the transport is currently configured enough to attempt a
  /// send. Drives the test-send button enable state and lets the router
  /// silently skip transports the user hasn't finished configuring.
  bool get isConfigured;

  /// Why this transport would send nothing for [message] although it is
  /// configured, or null when it will try. The router leaves a declining
  /// transport out, so a message is never reported as handed to a transport
  /// that drops it.
  String? declines(NotificationMessage message) => null;

  /// Fire a notification. Title and body arrive already rendered. A message
  /// this transport [declines] comes back as [NotificationResult.skipped].
  Future<NotificationResult> send(NotificationMessage message);

  /// Dispose any owned sockets / clients. The default is a no-op; only
  /// transports that own long-lived resources need to override.
  Future<void> dispose() async {}
}
