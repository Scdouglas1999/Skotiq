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

/// The notice named [name] with its [fields]. A host from before the notice
/// carried fields sends none; the row's own details hold the same values.
SequencerNotice? _noticeNamed(Object? name, Map<String, Object?> fields) =>
    switch (name) {
      'autofocus_continued' => const SequencerNotice.autofocusContinued(),
      'reject_streak' => SequencerNotice.rejectStreak(
        consecutiveRejects: wireOptInt(fields, 'consecutive_rejects') ?? 0,
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

/// The stop a row from a host before the `stop` field records, read from the
/// words those builds wrote. The words are fixed for those builds.
SequencerStop? _olderHostStop(
  String category,
  String summary,
  Map<String, Object?> details,
) {
  if (_isOlderHostCancelNotice(summary)) {
    return const SequencerStop.cancelled();
  }
  switch (category) {
    case 'manual_intervention' when summary.startsWith('Operator: stop'):
      return const SequencerStop.operator_();
    case 'system_event' when summary == 'Autopilot: stop':
      return const SequencerStop.autopilot();
    case 'system_event' when summary == 'System: stop':
      return SequencerStop.system(origin: wireString(details, 'origin'));
    // Only this action parked the mount and ended the run.
    case 'trigger_fired'
        when wireString(details, 'action').trim() == 'ParkAndAbort':
      return SequencerStop.trigger(
        triggerId: wireString(details, 'trigger_id'),
        triggerName: wireString(details, 'trigger_name'),
      );
  }
  return null;
}

/// The notice a host from before the `cancelled` kind sent for a cancelled
/// run, as an `Error` message and as the cancellation row's summary.
bool _isOlderHostCancelNotice(String text) {
  final normalized = text.trim().toLowerCase();
  return normalized == 'sequence cancelled' ||
      normalized == 'sequence canceled';
}

Map<String, Object?> _jsonObject(String? text) {
  if (text == null || text.isEmpty) return const {};
  try {
    return wireMap(jsonDecode(text));
  } on FormatException {
    return const {};
  }
}

/// What a host from before the `notice` field wrote on the rows and warnings
/// that carry one now. The words are fixed for those builds.
const Map<String, String> _olderHostSummaries = {
  'Autofocus failed — continuing with last-good focus': 'autofocus_continued',
  'Frames rejected in a row — the run continues': 'reject_streak',
  'Problem noticed — the run continues': 'problem_noticed',
};

const Map<String, String> _olderHostWarningSentences = {
  'The run continues. To have problems like this stop the run instead, turn '
          'on Stop the run for quality problems in Settings > Sequencer.':
      'problem_noticed',
  'and imaging continues on the last-good focus.': 'autofocus_continued',
  'Imaging continues, but check focus before trusting these frames.':
      'autofocus_continued',
  'The run continues and every frame is kept; rejects are in the Reject '
          'folder.':
      'reject_streak',
};

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
  // The remote envelope has carried the text as `error`.
  final message = wireOptString(d, 'message') ?? wireString(d, 'error');
  Object? noticeName = d[kSequencerNoticeKey];
  if (noticeName == null && severity == EventSeverity.warning) {
    for (final MapEntry(key: sentence, value: name)
        in _olderHostWarningSentences.entries) {
      if (message.contains(sentence)) noticeName = name;
    }
  }
  // A host from before the kind sends none: its warnings were notes and
  // everything else a failing step. One from before the `cancelled` kind sent
  // a cancellation as a failing step with a fixed notice.
  final kind =
      decodeSequencerErrorKind(d[kSequencerErrorKindKey]) ??
      (severity == EventSeverity.warning
          ? SequencerErrorKind.advisory
          : SequencerErrorKind.stepFailed);
  return SequencerEvent.error(
    message: message,
    kind:
        kind == SequencerErrorKind.stepFailed &&
            _isOlderHostCancelNotice(message)
        ? SequencerErrorKind.cancelled
        : kind,
    notice: _noticeNamed(noticeName, wireMap(d[kSequencerNoticeFieldsKey])),
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
  final category = wireString(d, 'category');
  final summary = wireString(d, 'summary');
  final detailsJson = wireString(d, 'details_json');
  final noticeName =
      d[kSequencerNoticeKey] ??
      (category == 'system_event' ? _olderHostSummaries[summary] : null);
  final fields = d[kSequencerNoticeFieldsKey];
  final stop = d[kSequencerStopKey];
  return SequencerEvent.decisionLogged(
    timestampIso: wireString(d, 'timestamp_iso'),
    category: category,
    summary: summary,
    detailsJson: detailsJson,
    nodeId: wireOptString(d, 'node_id'),
    sequenceRunId: wireOptInt(d, 'sequence_run_id'),
    notice: _noticeNamed(
      noticeName,
      fields == null ? _jsonObject(detailsJson) : wireMap(fields),
    ),
    stop: stop == null
        ? _olderHostStop(category, summary, _jsonObject(detailsJson))
        : _decodeStop(wireMap(stop)),
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
