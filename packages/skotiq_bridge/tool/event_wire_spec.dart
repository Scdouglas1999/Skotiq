// Where the event wire differs from "the variant's name and its fields in
// snake_case". These names are read by the web dashboard, the run-watch page
// and older clients, so they stay as they were first sent.

class VariantSpec {
  const VariantSpec({
    this.type,
    this.aliases = const [],
    this.keys = const {},
    this.flatten = const {},
    this.omitNull = const {},
    this.whenKey,
    this.customTypes,
    this.defaults = const {},
    this.required = const {},
  });

  /// Fractional fields the event is not that event without: when one is
  /// absent the event is refused instead of read as zero.
  final Set<String> required;

  /// Dart expressions for required fields that an older sender leaves out.
  final Map<String, String> defaults;

  /// The event type sent, when it is not the variant's name.
  final String? type;

  /// Other event types read as this variant.
  final List<String> aliases;

  /// Field name to wire key, for keys that are not the snake_case name.
  final Map<String, String> keys;

  /// Fields whose own fields are written straight into the event's data.
  final Set<String> flatten;

  /// Optional fields left out of the data when they are null.
  final Set<String> omitNull;

  /// For a variant that shares its event type with another: the data key
  /// whose presence means this variant.
  final String? whenKey;

  /// The event types a hand-written codec in `event_wire_custom.dart` reads
  /// and writes for this variant (`encode<Class>` and `decode<Class>`).
  final List<String>? customTypes;
}

/// A prefix on every event type of a union that shares its family with
/// another union.
const Map<String, String> unionTypePrefix = {'DepthLockEvent': 'DepthLock'};

/// Enums only the hand-written codecs read and write.
const Set<String> customCodecEnums = {'SequencerErrorKind'};

/// Enum values whose wire name is not the snake_case name.
const Map<String, Map<String, String>> enumWireNames = {
  'FrameType': {'darkFlat': 'darkFlat'},
};

const Map<String, VariantSpec> variantSpecs = {
  'ImagingEvent_ExposureStarted': VariantSpec(
    defaults: {'frameType': 'FrameType.light'},
  ),
  'DepthLockEvent_GoalUpdated': VariantSpec(
    keys: {'framesRemaining': 'framesRemaining'},
  ),
  'EquipmentEvent_PropertyChanged': VariantSpec(
    customTypes: [
      'PropertyChanged',
      'AutofocusProgress',
      'FocuserBacklashCalibrationProgress',
    ],
  ),
  'EquipmentEvent_CameraTemperatureChanged': VariantSpec(
    keys: {'coolerPower': 'coolerPower'},
  ),
  'EquipmentEvent_HeartbeatStatusChanged': VariantSpec(omitNull: {'lastRttMs'}),
  'EquipmentEvent_DeviceDiscovered': VariantSpec(omitNull: {'uniqueId'}),
  'SequencerEvent_Stopped': VariantSpec(
    aliases: ['SequenceStopped'],
    omitNull: {'sequenceRunId'},
  ),
  'SystemEvent_Notification': VariantSpec(omitNull: {'explicitTransports'}),
  'GuidingEvent_Settled': VariantSpec(type: 'SettleDone'),
  'GuidingEvent_LostStar': VariantSpec(type: 'StarLost'),
  'GuidingEvent_Looping': VariantSpec(type: 'LoopingExposures'),
  'GuidingEvent_Correction': VariantSpec(
    type: 'GuideStep',
    keys: {
      'ra': 'RADistance',
      'dec': 'DECDistance',
      'raRaw': 'RADistanceRaw',
      'decRaw': 'DECDistanceRaw',
    },
    // A guide step without a distance is not a perfect step.
    required: {'raRaw', 'decRaw'},
  ),
  'GuidingEvent_StarSelected': VariantSpec(keys: {'x': 'X', 'y': 'Y'}),
  'GuidingEvent_AppState': VariantSpec(keys: {'state': 'State'}),
  'GuidingEvent_GuideStats': VariantSpec(
    keys: {'snr': 'SNR', 'starMass': 'StarMass'},
  ),
  'ImagingEvent_ExposureStartedWithFrame': VariantSpec(
    type: 'ExposureStarted',
    keys: {'frameNumber': 'frame', 'totalFrames': 'total'},
    whenKey: 'frame',
    defaults: {'frameType': 'FrameType.light'},
  ),
  'ImagingEvent_ExposureCompletedWithFrame': VariantSpec(
    type: 'ExposureCompleted',
    keys: {'frameNumber': 'frame', 'totalFrames': 'total'},
    whenKey: 'frame',
  ),
  'ImagingEvent_ExposureProgress': VariantSpec(
    keys: {'remainingSecs': 'remainingSecs'},
  ),
  'ImagingEvent_ExposureFailedOld': VariantSpec(
    type: 'ExposureFailed',
    whenKey: 'reason',
  ),
  'ImagingEvent_IntegrationProgress': VariantSpec(
    omitNull: {'framesDone', 'framesTotal'},
  ),
  'ImagingEvent_IntegrationTelemetry': VariantSpec(
    customTypes: ['IntegrationTelemetry'],
  ),
  'SequencerEvent_Paused': VariantSpec(aliases: ['SequencePaused']),
  'SequencerEvent_Resumed': VariantSpec(aliases: ['SequenceResumed']),
  'SequencerEvent_Completed': VariantSpec(aliases: ['SequenceCompleted']),
  'SequencerEvent_Failed': VariantSpec(type: 'SequenceFailed'),
  'SequencerEvent_Error': VariantSpec(customTypes: ['Error']),
  'SequencerEvent_DecisionLogged': VariantSpec(customTypes: ['DecisionLogged']),
  'SequencerEvent_FrameAccepted': VariantSpec(flatten: {'capture'}),
  'SequencerEvent_FrameRejected': VariantSpec(flatten: {'capture'}),
  // A frame event from a host that sends no capture record still decodes.
  'FrameCaptureMetadata': VariantSpec(
    defaults: {
      'exposureSecs': '0',
      'binX': '1',
      'binY': '1',
      'frameType': "'light'",
    },
  ),
};
