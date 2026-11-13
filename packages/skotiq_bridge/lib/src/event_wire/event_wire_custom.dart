import 'dart:convert';

import '../event.dart';
import 'event_wire.g.dart';
import 'wire_values.dart';

/// The events whose wire form is not their fields one for one. The generated
/// codec calls these by name (see `tool/event_wire_spec.dart`).

/// Key of the kind in a sequencer `Error` event's data.
const String kSequencerErrorKindKey = 'kind';

/// Key of the notice's name in a sequencer `DecisionLogged` or `Error`
/// event's data, and of the notice's own fields beside it.
const String kSequencerNoticeKey = 'notice';
const String kSequencerNoticeFieldsKey = 'notice_fields';

/// Key of the stop a sequencer `DecisionLogged` row records.
const String kSequencerStopKey = 'stop';

extension SequencerNoticeWire on SequencerNotice {
  /// The value of the event's `notice` field.
  String get wireName => switch (this) {
    SequencerNotice_AutofocusContinued() => 'autofocus_continued',
    SequencerNotice_RejectStreak() => 'reject_streak',
    SequencerNotice_ProblemNoticed() => 'problem_noticed',
  };

  Map<String, Object?> get _wireFields => switch (this) {
    SequencerNotice_AutofocusContinued() => const {},
    SequencerNotice_RejectStreak(:final consecutiveRejects, :final reason) => {
      'consecutive_rejects': consecutiveRejects,
      'reason': reason,
    },
    SequencerNotice_ProblemNoticed(:final source, :final problem) => {
      'source': source,
      'problem': problem,
    },
  };
}

Map<String, Object?> _encodeNotice(SequencerNotice? notice) => {
  kSequencerNoticeKey: notice?.wireName,
  if (notice != null && notice._wireFields.isNotEmpty)
    kSequencerNoticeFieldsKey: notice._wireFields,
};

/// The notice named [name] with its [fields].
SequencerNotice? _noticeNamed(Object? name, Map<String, Object?> fields) =>
    switch (name) {
      'autofocus_continued' => const SequencerNotice.autofocusContinued(),
      'reject_streak' => SequencerNotice.rejectStreak(
        consecutiveRejects: wireInt(fields, 'consecutive_rejects'),
        reason: wireString(fields, 'reason'),
      ),
      'problem_noticed' => SequencerNotice.problemNoticed(
        source: wireString(fields, 'source'),
        problem: wireString(fields, 'problem'),
      ),
      _ => null,
    };

Map<String, Object?> _encodeStop(SequencerStop stop) => switch (stop) {
  SequencerStop_Cancelled() => const {'by': 'cancelled'},
  SequencerStop_Operator() => const {'by': 'operator'},
  SequencerStop_Autopilot() => const {'by': 'autopilot'},
  SequencerStop_System(:final origin) => {'by': 'system', 'origin': origin},
  SequencerStop_Trigger(:final triggerId, :final triggerName) => {
    'by': 'trigger',
    'trigger_id': triggerId,
    'trigger_name': triggerName,
  },
};

SequencerStop? _decodeStop(Map<String, Object?> d) => switch (d['by']) {
  'cancelled' => const SequencerStop.cancelled(),
  'operator' => const SequencerStop.operator_(),
  'autopilot' => const SequencerStop.autopilot(),
  'system' => SequencerStop.system(origin: wireString(d, 'origin')),
  'trigger' => SequencerStop.trigger(
    triggerId: wireString(d, 'trigger_id'),
    triggerName: wireString(d, 'trigger_name'),
  ),
  _ => null,
};

Map<String, Object?> _jsonObject(String? text) {
  if (text == null || text.isEmpty) return const {};
  try {
    return wireMap(jsonDecode(text));
  } on FormatException {
    return const {};
  }
}

WireEvent encodeSequencerEventError(SequencerEvent_Error event) => (
  'Error',
  {
    'message': event.message,
    kSequencerErrorKindKey: encodeSequencerErrorKind(event.kind),
    ..._encodeNotice(event.notice),
  },
);

SequencerEvent? decodeSequencerEventError(
  String type,
  Map<String, Object?> d,
  EventSeverity severity,
) {
  final kind = decodeSequencerErrorKind(d[kSequencerErrorKindKey]);
  if (kind == null) {
    throw FormatException(
      'Sequencer Error with no known kind: ${d[kSequencerErrorKindKey]}',
    );
  }
  return SequencerEvent.error(
    message: wireString(d, 'message'),
    kind: kind,
    notice: _noticeNamed(
      d[kSequencerNoticeKey],
      wireMap(d[kSequencerNoticeFieldsKey]),
    ),
  );
}

WireEvent encodeSequencerEventDecisionLogged(
  SequencerEvent_DecisionLogged event,
) => (
  'DecisionLogged',
  {
    'timestamp_iso': event.timestampIso,
    'category': event.category,
    'summary': event.summary,
    'details_json': event.detailsJson,
    'node_id': event.nodeId,
    'sequence_run_id': event.sequenceRunId,
    ..._encodeNotice(event.notice),
    if (event.stop case final stop?) kSequencerStopKey: _encodeStop(stop),
  },
);

SequencerEvent? decodeSequencerEventDecisionLogged(
  String type,
  Map<String, Object?> d,
  EventSeverity severity,
) {
  final stop = d[kSequencerStopKey];
  return SequencerEvent.decisionLogged(
    timestampIso: wireString(d, 'timestamp_iso'),
    category: wireString(d, 'category'),
    summary: wireString(d, 'summary'),
    detailsJson: wireString(d, 'details_json'),
    nodeId: wireOptString(d, 'node_id'),
    sequenceRunId: wireOptInt(d, 'sequence_run_id'),
    notice: _noticeNamed(
      d[kSequencerNoticeKey],
      wireMap(d[kSequencerNoticeFieldsKey]),
    ),
    stop: stop == null ? null : _decodeStop(wireMap(stop)),
  );
}

/// Property changes that have always traveled under the property's own name.
const _namedProperties = {
  'AutofocusProgress',
  'FocuserBacklashCalibrationProgress',
};

WireEvent encodeEquipmentEventPropertyChanged(
  EquipmentEvent_PropertyChanged event,
) => _namedProperties.contains(event.property)
    ? (
        event.property,
        {
          'device_type': event.deviceType,
          'device_id': event.deviceId,
          'detail': event.value,
        },
      )
    : (
        'PropertyChanged',
        {
          'device_type': event.deviceType,
          'device_id': event.deviceId,
          'property': event.property,
          'value': event.value,
        },
      );

EquipmentEvent? decodeEquipmentEventPropertyChanged(
  String type,
  Map<String, Object?> d,
  EventSeverity severity,
) => EquipmentEvent.propertyChanged(
  deviceType: wireString(d, 'device_type'),
  deviceId: wireString(d, 'device_id'),
  property: type == 'PropertyChanged' ? wireString(d, 'property') : type,
  value: wireString(d, type == 'PropertyChanged' ? 'value' : 'detail'),
);

/// A Darkroom pass report. Its details cross the bridge as JSON text and
/// travel as the object they are.
WireEvent encodeImagingEventIntegrationTelemetry(
  ImagingEvent_IntegrationTelemetry event,
) => (
  'IntegrationTelemetry',
  {
    'run_id': event.runId,
    'kind': event.kind,
    'detail': _jsonObject(event.detailJson),
  },
);

ImagingEvent? decodeImagingEventIntegrationTelemetry(
  String type,
  Map<String, Object?> d,
  EventSeverity severity,
) => ImagingEvent.integrationTelemetry(
  runId: wireString(d, 'run_id'),
  kind: wireString(d, 'kind'),
  detailJson: jsonEncode(wireMap(d['detail'])),
);
