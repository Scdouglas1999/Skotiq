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
    final kind = switch (imagingEventOf(event)) {
      ImagingEvent_ExposureFailed() ||
      ImagingEvent_ExposureFailedOld() => _ExposureEventKind.failed,
      ImagingEvent_ExposureCancelled() => _ExposureEventKind.cancelled,
      ImagingEvent_ExposureComplete(:final success) =>
        success ? _ExposureEventKind.completedOk : _ExposureEventKind.failed,
      ImagingEvent_ExposureCompleted() ||
      ImagingEvent_ExposureCompletedWithFrame() =>
        _ExposureEventKind.completedOk,
      _ => _ExposureEventKind.notTerminal,
    };
    if (kind == _ExposureEventKind.notTerminal) return kind;
    if (!eventMayBeFromCamera(event, deviceId)) {
      return _ExposureEventKind.notTerminal;
    }
    return kind;
  }
}
