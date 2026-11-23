part of '../guiding_provider.dart';

/// What a start of guiding gets on top of the settle timeout before it
/// fails: calibration can precede the first settle. One figure for every
/// caller that waits for the settle.
const Duration guideCalibrationAllowance = Duration(seconds: 300);

/// Starts guiding through [guider] and completes once [events] reports that
/// the guider settled.
///
/// The subscription opens before the start command so an early settle is
/// not missed. A lost star or a stop while settling fails the call; so does
/// no settle within the settle timeout plus [guideCalibrationAllowance].
Future<void> startGuidingAndSettle({
  required Phd2Controller guider,
  required Stream<core_events.SkotiqEvent> events,
  required GuideSettle settle,
}) async {
  final settled = Completer<void>();
  final subscription = events.listen((event) {
    final payload = typedEventFromWire(event)?.payload;
    if (payload is! EventPayload_Guiding || settled.isCompleted) return;
    switch (payload.field0) {
      case GuidingEvent_Settled():
        settled.complete();
      case GuidingEvent_LostStar():
        settled.completeError(
          StateError('Guiding lost the star while settling'),
        );
      case GuidingEvent_GuidingStopped():
        settled.completeError(StateError('Guiding stopped while settling'));
      default:
    }
  });
  try {
    await guider.startGuiding();
    await settled.future.timeout(
      Duration(seconds: settle.timeoutSeconds.round()) +
          guideCalibrationAllowance,
      onTimeout: () => throw TimeoutException('Guiding did not report settled'),
    );
  } finally {
    await subscription.cancel();
  }
}
