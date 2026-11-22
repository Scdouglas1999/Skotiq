import '../models/backend/event_types.dart' as wire;
import 'bridge_event_codec.dart';
import 'bridge_events.dart';

/// The property an autofocus run reports each point under.
const String autofocusProgressProperty = 'AutofocusProgress';

/// Whether [event] is per-tick telemetry: it arrives many times a second
/// while guiding, exposing or running a step, and says nothing once it is
/// old. Each reader adds the per-tick events of its own concern (the
/// narrator's integration and sensor-temperature reports, the night log's
/// dither and frame-watch reports).
///
/// An event this build cannot decode (a host-made, sync, job or session
/// event) is not telemetry.
bool isPerTickTelemetry(wire.SkotiqEvent event) => switch (typedEventFromWire(
  event,
)?.payload) {
  EventPayload_Imaging(field0: ImagingEvent_ExposureProgress()) ||
  EventPayload_Guiding(
    field0: GuidingEvent_Correction() || GuidingEvent_GuideStats(),
  ) ||
  EventPayload_Equipment(field0: EquipmentEvent_CameraTemperatureChanged()) ||
  EventPayload_Sequencer(
    field0: SequencerEvent_InstructionProgress() || SequencerEvent_Progress(),
  ) => true,
  EventPayload_Equipment(
    field0: EquipmentEvent_PropertyChanged(:final property),
  ) =>
    property == autofocusProgressProperty,
  _ => false,
};
