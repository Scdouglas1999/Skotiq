// Base interface every transport implements.
//
// Why an abstract class rather than a typedef function: each transport
// needs a stable identity (`kind`), a "is the config valid enough to
// send?" check (drives the UI grey-out and test-send button), and a
// shared async send entry point. Subclasses live in sibling files in
// `transports/`.

import '../../../models/notification/notification_categories.dart';

/// Common contract for every notification transport.
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

  /// Fire a notification.
  ///
  /// [category] gives the transport room to colour-code embeds (Discord)
  /// or set priority (Pushover). [title] and [body] arrive
  /// already-rendered (interpolation applied upstream by the router).
  Future<NotificationResult> send({
    required NotificationCategory category,
    required String title,
    required String body,
  });

  /// Dispose any owned sockets / clients. The default is a no-op; only
  /// transports that own long-lived resources need to override.
  Future<void> dispose() async {}
}
