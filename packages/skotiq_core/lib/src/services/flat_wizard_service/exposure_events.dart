part of '../flat_wizard_service.dart';

extension _FlatWizardExposureEvents on FlatWizardService {
  /// Classify [event] relative to an exposure we started on [deviceId].
  ///
  /// Returns [_ExposureEventKind.notTerminal] for anything that must NOT settle
  /// the wait: non-imaging categories, non-terminal event types, and — the
  /// correlation guard — a terminal event tagged with a *different* device id.
  _ExposureEventKind _classifyExposureEvent(
    SkotiqEvent event,
    String deviceId,
  ) {
    if (event.category != EventCategory.imaging) {
      return _ExposureEventKind.notTerminal;
    }
    if (!_terminalExposureEventTypes.contains(event.eventType)) {
      return _ExposureEventKind.notTerminal;
    }
    // Device correlation: if the event names a device, it must be ours.
    for (final key in _deviceIdKeys) {
      final raw = event.data[key];
      if (raw != null &&
          raw.toString().isNotEmpty &&
          raw.toString() != deviceId) {
        return _ExposureEventKind.notTerminal;
      }
    }
    switch (event.eventType) {
      case 'ExposureFailed':
        return _ExposureEventKind.failed;
      case 'ExposureCancelled':
        return _ExposureEventKind.cancelled;
      case 'ExposureComplete':
        // Legacy event carries an explicit success flag.
        final success = event.data['success'];
        return success == false
            ? _ExposureEventKind.failed
            : _ExposureEventKind.completedOk;
      default: // ExposureCompleted
        return _ExposureEventKind.completedOk;
    }
  }
}
