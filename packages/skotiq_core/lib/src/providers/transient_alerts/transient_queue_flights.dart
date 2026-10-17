part of '../transient_alert_provider.dart';

final _transientQueueFlightsProvider =
    Provider<Map<String, Future<CelestialTarget?>>>((ref) => {});

/// Queue a transient alert for tonight's observation.
///
/// This function:
/// 1. Creates a new target from the alert's coordinates
/// 2. Marks the alert as queued after creation succeeds
/// 3. Shows a notification confirming the action
///
/// Parameters:
/// - [ref]: WidgetRef for accessing providers
/// - [alert]: The transient alert to queue
///
/// Returns the created target, or null if creation failed.
Future<CelestialTarget?> queueTransientForTonight(
  WidgetRef ref,
  TransientAlert alert,
) async {
  final flights = ref.read(_transientQueueFlightsProvider);
  final existing = flights[alert.id];
  if (existing != null) return existing;

  final operation = _performQueueTransientForTonight(ref, alert);
  flights[alert.id] = operation;
  try {
    return await operation;
  } finally {
    if (identical(flights[alert.id], operation)) {
      flights.remove(alert.id)?.ignore();
    }
  }
}

Future<CelestialTarget?> _performQueueTransientForTonight(
  WidgetRef ref,
  TransientAlert alert,
) async {
  final logger = ref.read(loggingServiceProvider);
  final statesNotifier = ref.read(transientAlertStatesProvider.notifier);
  final notificationNotifier = ref.read(uiNotificationProvider.notifier);
  try {
    // Map TransientType to TargetType
    final targetType = _mapTransientTypeToTargetType(alert.type);

    // Build notes combining all transient info
    final alertNotes = StringBuffer();
    alertNotes.writeln(
      'Transient alert from ${alert.source.name.toUpperCase()}',
    );
    if (alert.classification != null) {
      alertNotes.writeln('Classification: ${alert.classification}');
    }
    if (alert.notes != null) {
      alertNotes.writeln('Alert notes: ${alert.notes}');
    }
    alertNotes.writeln(
      'Queued from transient alert on ${DateTime.now().toIso8601String()}',
    );
    alertNotes.writeln(
      'Discovery time: ${alert.discoveryTime.toIso8601String()}',
    );
    if (alert.sourceUrl != null) {
      alertNotes.writeln('Source URL: ${alert.sourceUrl}');
    }

    final targetId = await ref
        .read(targetLibraryServiceProvider)
        .createTarget(
          name: alert.name,
          catalogId: alert.id,
          raHours: alert.raHours,
          decDegrees: alert.decDegrees,
          objectType: targetType.name,
          magnitude: alert.magnitude,
          isFavorite: false,
          priority: alert.priority,
          notes: alertNotes.toString(),
        );

    // Create the target object to return
    final target = CelestialTarget(
      id: targetId,
      name: alert.name,
      catalogId: alert.id,
      raHours: alert.raHours,
      decDegrees: alert.decDegrees,
      objectType: targetType,
      magnitude: alert.magnitude,
      priority: alert.priority,
    );

    // The durable target is the primary action. Mark the feed item queued only
    // after target creation succeeds so a failed create never leaves an alert
    // falsely labelled as queued. A status-write failure must not turn a real,
    // successfully-created target into a reported total failure.
    var statusSaved = true;
    try {
      await statesNotifier.queue(alert.id);
    } catch (e) {
      statusSaved = false;
      logger.error(
        'Target $targetId was created for transient ${alert.name}, but its '
        'queued state could not be saved: $e',
        source: 'queueTransientForTonight',
      );
    }

    // Show notification
    notificationNotifier.showSuccess(
      'Added ${alert.name} to your target library',
      title: 'Added to Library',
    );
    if (!statusSaved) {
      notificationNotifier.showWarning(
        'The target was added, but this alert could not be marked as queued.',
        title: 'Alert Status Not Saved',
      );
    }

    logger.info(
      'Queued transient ${alert.name} (ID: ${alert.id}) as target ID: $targetId',
      source: 'queueTransientForTonight',
    );

    return target;
  } catch (e) {
    logger.error(
      'Failed to queue transient ${alert.name}: $e',
      source: 'queueTransientForTonight',
    );
    notificationNotifier.showError(
      'Failed to queue ${alert.name}: $e',
      title: 'Queue Error',
    );
    return null;
  }
}

/// Maps a TransientType to a TargetType for target creation.
TargetType _mapTransientTypeToTargetType(TransientType type) {
  switch (type) {
    case TransientType.nova:
    case TransientType.supernova:
    case TransientType.cataclysmic:
    case TransientType.variableStar:
    case TransientType.gammaRayBurst:
      return TargetType.star;
    case TransientType.comet:
      return TargetType.comet;
    case TransientType.asteroid:
      return TargetType.asteroid;
    case TransientType.other:
      return TargetType.other;
  }
}

// Refresh action

/// Force refresh the transient alerts by clearing the service cache.
///
/// This clears the internal cache and triggers a new fetch.
void refreshTransientAlerts(WidgetRef ref) {
  final service = ref.read(transientAlertServiceProvider);
  service.clearCache();

  // Invalidate the provider to trigger a fresh fetch
  ref.invalidate(activeTransientAlertsProvider);

  final logger = ref.read(loggingServiceProvider);
  logger.info(
    'Transient alerts refresh triggered',
    source: 'refreshTransientAlerts',
  );
}
