import 'package:flutter_test/flutter_test.dart';
import 'package:nightshade_core/nightshade_core.dart';

/// A sequence file saved before 2026-10-06, when quality triggers paused or
/// ended the run. Owner decision that day: only a risk to the hardware pauses
/// or ends a run by itself, so importing it moves those stops to notices, as
/// the database migration to schema 61 does for saved sequences.
Map<String, dynamic> _oldFile() => {
  'schemaVersion': 1,
  'version': '2.0',
  'name': 'Old night',
  'rootNodeId': 'root',
  'nodes': {
    'root': {
      'id': 'root',
      'nodeType': 'InstructionSet',
      'name': 'Root',
      'childIds': ['hfr', 'weather', 'lights'],
    },
    'hfr': {
      'id': 'hfr',
      'nodeType': 'Recovery',
      'name': 'HFR watch',
      'parentId': 'root',
      'recoveryAction': 'pause',
      'triggerType': 'hfrDegraded',
    },
    'weather': {
      'id': 'weather',
      'nodeType': 'Recovery',
      'name': 'Weather',
      'parentId': 'root',
      'recoveryAction': 'parkAndAbort',
      'triggerType': 'weatherUnsafe',
    },
    'lights': {
      'id': 'lights',
      'nodeType': 'TakeExposure',
      'name': 'Lights',
      'parentId': 'root',
      'durationSecs': 120.0,
      'count': 10,
      'triggers': [
        {
          'condition': {'GuidingRmsAbove': 2.0},
          'action': 'PauseAndRecalibrate',
          'debounce_secs': 10.0,
        },
        {
          'condition': {'HfrAbove': 4.0},
          'action': 'Autofocus',
          'debounce_secs': 10.0,
        },
      ],
    },
  },
};

void main() {
  test('an old file has its quality stops moved to notices on import', () {
    final sequence = SequenceFileService().parseFromMap(_oldFile());

    final hfr = sequence.nodes['hfr'] as RecoveryNode;
    final weather = sequence.nodes['weather'] as RecoveryNode;
    final lights = sequence.nodes['lights'] as ExposureNode;
    expect(hfr.recoveryAction, RecoveryActionType.notify);
    expect(weather.recoveryAction, RecoveryActionType.parkAndAbort);
    expect(lights.triggers.map((t) => t['action']), ['Notify', 'Autofocus']);
  });

  test('a stop chosen after the move survives export and import', () {
    final service = SequenceFileService();
    final imported = service.parseFromMap(_oldFile());
    final hfr = imported.nodes['hfr'] as RecoveryNode;
    final chosen = imported.copyWith(
      nodes: {
        ...imported.nodes,
        'hfr': hfr.copyWith(recoveryAction: RecoveryActionType.pause),
      },
    );

    final reimported = service.parseFromMap(service.sequenceToMap(chosen));

    expect(
      (reimported.nodes['hfr'] as RecoveryNode).recoveryAction,
      RecoveryActionType.pause,
    );
  });
}
