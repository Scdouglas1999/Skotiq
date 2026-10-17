// Migration test for the v60 -> v61 step: saved sequences' quality stops
// become notices (owner decision 2026-10-06: only a risk to the hardware
// pauses or ends a run by itself).
//
// A v60 database is simulated by writing the old rows and rewinding
// `PRAGMA user_version = 60`; reopening runs onUpgrade(60, 61).

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';

/// node id -> (specific type, stored properties) as a v60 build saved them.
final Map<String, (String, Map<String, dynamic>)> _v60Nodes = {
  'hfr-pause': (
    'Recovery',
    {'triggerType': 'hfrDegraded', 'recoveryAction': 'pause', 'maxRetries': 3},
  ),
  'guiding-retry': (
    'Recovery',
    {'triggerType': 'guidingFailed', 'recoveryAction': 'retry'},
  ),
  'drift-park': (
    'Recovery',
    {'triggerType': 'driftLimit', 'recoveryAction': 'parkAndAbort'},
  ),
  'focus-drift-wait': (
    'Recovery',
    {'triggerType': 'focusDrift', 'recoveryAction': 'pauseAndWaitForClear'},
  ),
  'transparency-pause': (
    'Recovery',
    {'triggerType': 'transparencyDropped', 'recoveryAction': 'pause'},
  ),
  'hfr-autofocus': (
    'Recovery',
    {'triggerType': 'hfrDegraded', 'recoveryAction': 'autofocus'},
  ),
  'transparency-switch': (
    'Recovery',
    {
      'triggerType': 'transparencyDropped',
      'recoveryAction': 'switchTargetOrFilter',
    },
  ),
  'weather-park': (
    'Recovery',
    {'triggerType': 'weatherUnsafe', 'recoveryAction': 'parkAndAbort'},
  ),
  'dawn-park': (
    'Recovery',
    {'triggerType': 'dawnApproaching', 'recoveryAction': 'parkAndAbort'},
  ),
  'altitude-pause': (
    'Recovery',
    {'triggerType': 'altitudeLimit', 'recoveryAction': 'pause'},
  ),
  'tracking-pause': (
    'Recovery',
    {'triggerType': 'mountTrackingLost', 'recoveryAction': 'pause'},
  ),
  'dome-park': (
    'Recovery',
    {'triggerType': 'domeShutterNotOpen', 'recoveryAction': 'parkAndAbort'},
  ),
  'step-retry': ('Recovery', {'triggerType': null, 'recoveryAction': 'retry'}),
  'lights': (
    'TakeExposure',
    {
      'durationSecs': 180.0,
      'count': 20,
      'triggers': [
        {
          'condition': {'HfrAbove': 3.5},
          'action': 'PauseAndRecalibrate',
          'debounce_secs': 10.0,
        },
        {
          'condition': {'GuidingRmsAbove': 2.0},
          'action': 'Abort',
          'debounce_secs': 10.0,
        },
        {
          'condition': {
            'DriftAbove': {'ra_px': 30.0, 'dec_px': 30.0},
          },
          'action': 'Autofocus',
          'debounce_secs': 10.0,
        },
      ],
    },
  ),
};

/// What each node's action must be after the upgrade.
const Map<String, Object> _expected = {
  'hfr-pause': 'notify',
  'guiding-retry': 'notify',
  'drift-park': 'notify',
  'focus-drift-wait': 'notify',
  'transparency-pause': 'notify',
  'hfr-autofocus': 'autofocus',
  'transparency-switch': 'switchTargetOrFilter',
  'weather-park': 'parkAndAbort',
  'dawn-park': 'parkAndAbort',
  'altitude-pause': 'pause',
  'tracking-pause': 'pause',
  'dome-park': 'parkAndAbort',
  'step-retry': 'retry',
  'lights': ['Notify', 'Notify', 'Autofocus'],
};

void main() {
  group('migration onUpgrade v60 -> v61 (quality stops become notices)', () {
    late File dbFile;

    setUp(() async {
      final dir = await Directory.systemTemp.createTemp('skotiq_v60_v61_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      dbFile = File('${dir.path}/skotiq.db');
    });

    Future<void> writeV60({required bool asTemplate}) async {
      final setup = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        await setup.customStatement(
          'INSERT INTO sequences (id, name, is_template) VALUES (?, ?, ?)',
          [1, 'Night', asTemplate ? 1 : 0],
        );
        var order = 0;
        for (final entry in _v60Nodes.entries) {
          final (specificType, properties) = entry.value;
          await setup.customStatement(
            'INSERT INTO sequence_nodes '
            '(node_id, sequence_id, node_type, specific_type, name, '
            'properties, order_index) VALUES (?, ?, ?, ?, ?, ?, ?)',
            [
              entry.key,
              1,
              specificType == 'Recovery' ? 'logic' : 'instruction',
              specificType,
              entry.key,
              jsonEncode(properties),
              order++,
            ],
          );
        }
        await setup.customStatement('PRAGMA user_version = 60');
      } finally {
        await setup.close();
      }
    }

    Future<Map<String, Object?>> reopenAndReadActions() async {
      final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final version = await db
            .customSelect('PRAGMA user_version')
            .getSingle();
        expect(version.data['user_version'], db.schemaVersion);
        final rows = await db
            .customSelect(
              'SELECT node_id, specific_type, properties FROM sequence_nodes '
              'WHERE sequence_id = ?',
              variables: [Variable.withInt(1)],
            )
            .get();
        return {
          for (final row in rows)
            row.read<String>('node_id'): _actionOf(
              row.read<String>('specific_type'),
              jsonDecode(row.read<String>('properties'))
                  as Map<String, dynamic>,
            ),
        };
      } finally {
        await db.close();
      }
    }

    test('quality stops notify; safety triggers and other actions are '
        'untouched', () async {
      await writeV60(asTemplate: false);
      expect(await reopenAndReadActions(), _expected);
    });

    test('templates are moved the same way', () async {
      await writeV60(asTemplate: true);
      expect(await reopenAndReadActions(), _expected);
    });

    test('the other stored fields are kept', () async {
      await writeV60(asTemplate: false);
      final db = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      try {
        final row = await db
            .customSelect(
              "SELECT properties FROM sequence_nodes WHERE node_id = 'hfr-pause'",
            )
            .getSingle();
        expect(jsonDecode(row.read<String>('properties')), {
          'triggerType': 'hfrDegraded',
          'recoveryAction': 'notify',
          'maxRetries': 3,
        });
        final lights = await db
            .customSelect(
              "SELECT properties FROM sequence_nodes WHERE node_id = 'lights'",
            )
            .getSingle();
        final props =
            jsonDecode(lights.read<String>('properties'))
                as Map<String, dynamic>;
        expect(props['durationSecs'], 180.0);
        expect((props['triggers'] as List).first, {
          'condition': {'HfrAbove': 3.5},
          'action': 'Notify',
          'debounce_secs': 10.0,
        });
      } finally {
        await db.close();
      }
    });

    test('runs once: a pause chosen after the upgrade sticks on later '
        'opens', () async {
      await writeV60(asTemplate: false);
      expect(await reopenAndReadActions(), _expected);

      final operator = SkotiqDatabase.forTesting(NativeDatabase(dbFile));
      await operator.customStatement(
        'UPDATE sequence_nodes SET properties = ? WHERE node_id = ?',
        [
          jsonEncode({'triggerType': 'hfrDegraded', 'recoveryAction': 'pause'}),
          'hfr-pause',
        ],
      );
      await operator.close();

      final reopened = await reopenAndReadActions();
      expect(reopened['hfr-pause'], 'pause');
      expect((await reopenAndReadActions())['hfr-pause'], 'pause');
    });
  });
}

Object? _actionOf(String specificType, Map<String, dynamic> properties) {
  if (specificType == 'Recovery') return properties['recoveryAction'];
  return [
    for (final trigger in properties['triggers'] as List)
      (trigger as Map)['action'],
  ];
}
