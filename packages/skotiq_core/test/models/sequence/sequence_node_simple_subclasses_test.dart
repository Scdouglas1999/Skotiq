// Cover for the structurally-simple SequenceNode subclasses.
//
// "Simple" here means: plain `?? this.X` copyWith for every field, NO
// JSON serde on the model itself (sequences are serialised by the
// editor / repository layer, not by the model — except for the
// node-type-specific Rust-config encoders covered by
// `trigger_type_serialization_test.dart` and the SciencePhotometry
// fromRustConfigJson which is in the complex file).
//
// Covered here:
//   * InstructionSetNode
//   * ParallelNode
//   * SlewNode
//   * CenterNode
//   * AutofocusNode
//   * DitherNode
//   * StartGuidingNode
//   * StopGuidingNode
//   * FilterChangeNode
//   * CoolCameraNode
//   * WarmCameraNode
//   * RotatorNode
//   * ParkNode
//   * UnparkNode
//   * WaitTimeNode
//   * DelayNode
//   * ScriptNode
//   * OpenDomeNode
//   * CloseDomeNode
//   * ParkDomeNode
//   * PolarAlignmentNode
//   * OpenCoverNode
//   * CloseCoverNode
//   * CalibratorOnNode
//   * CalibratorOffNode
//   * PluginInstructionNode
//
// Each class gets:
//   - constructor smoke test (defaults exist, id auto-generated)
//   - copyWith each-field-mutates AND copyWith() no-args preserves
//   - equality (same fields => equal; one diff => not equal)
//   - nodeType / category / iconName / requiredDevices pin
//     (these are CONSTANT-returning getters, and the same constants must
//     come out however the dispatch is routed; `nodeType` in particular
//     appears in serialized form and in Rust-side dispatch keys)
//
// Every SequenceNode subclass defines `nodeType` as a string literal (e.g.
// 'SlewToTarget', 'TakeExposure'). These literals are the Rust serde
// discriminant, so a rename breaks every persisted sequence.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('InstructionSetNode', () {
    test('node_type_and_category_pin', () {
      final n = InstructionSetNode();
      expect(n.nodeType, equals('InstructionSet'));
      expect(n.iconName, equals('list'));
      expect(n.category, equals(NodeCategory.logic));
      expect(n.requiredDevices, isEmpty);
    });

    test('copyWith_preserves_base_fields', () {
      final n = InstructionSetNode(name: 'Steps', orderIndex: 5);
      final copy = n.copyWith();
      expect(copy.id, equals(n.id));
      expect(copy.name, equals('Steps'));
      expect(copy.orderIndex, equals(5));
    });

    test('copyWith_each_base_field_mutates', () {
      final n = InstructionSetNode();
      expect(n.copyWith(name: 'X').name, equals('X'));
      expect(n.copyWith(isEnabled: false).isEnabled, isFalse);
      expect(n.copyWith(childIds: ['c']).childIds, equals(['c']));
      expect(n.copyWith(parentId: 'p').parentId, equals('p'));
      expect(n.copyWith(orderIndex: 99).orderIndex, equals(99));
      expect(n.copyWith(comment: 'note').comment, equals('note'));
    });

    test('equality_with_same_id_and_fields', () {
      final a = InstructionSetNode(id: 'i1', name: 'A');
      final b = InstructionSetNode(id: 'i1', name: 'A');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(b.copyWith(name: 'B'))));
    });
  });

  group('ParallelNode', () {
    test('node_type_and_category_pin', () {
      final n = ParallelNode();
      expect(n.nodeType, equals('Parallel'));
      expect(n.iconName, equals('git-branch'));
      expect(n.category, equals(NodeCategory.logic));
    });

    test('copyWith_each_field', () {
      final n = ParallelNode(requiredSuccesses: 2);
      expect(n.copyWith(requiredSuccesses: 3).requiredSuccesses, equals(3));
      expect(n.copyWith().requiredSuccesses, equals(2));
    });

    test('equality', () {
      final a = ParallelNode(id: 'p', requiredSuccesses: 2);
      final b = ParallelNode(id: 'p', requiredSuccesses: 2);
      expect(a, equals(b));
      expect(a, isNot(equals(b.copyWith(requiredSuccesses: 3))));
    });
  });

  group('SlewNode', () {
    test('node_type_iconName_and_required_devices_pin', () {
      final n = SlewNode();
      expect(n.nodeType, equals('SlewToTarget'));
      expect(n.iconName, equals('compass'));
      expect(n.category, equals(NodeCategory.instruction));
      expect(n.requiredDevices, equals({DeviceType.mount}));
    });

    test('default_uses_target_coords', () {
      final n = SlewNode();
      expect(n.useTargetCoords, isTrue);
      expect(n.customRa, isNull);
      expect(n.customDec, isNull);
    });

    test('copyWith_high_precision_ra_dec', () {
      // Realistic RA/Dec: M42 = 5h 35m 17.3s, -5d 23m 28s
      final n = SlewNode();
      final copy = n.copyWith(
        useTargetCoords: false,
        customRa: 5.588147,
        customDec: -5.39111,
      );
      expect(copy.useTargetCoords, isFalse);
      expect(copy.customRa, equals(5.588147));
      expect(copy.customDec, equals(-5.39111));
    });

    test('copyWith_no_args_preserves_custom_coords', () {
      final n = SlewNode(customRa: 1.0, customDec: 2.0, useTargetCoords: false);
      final copy = n.copyWith();
      expect(copy.useTargetCoords, isFalse);
      expect(copy.customRa, equals(1.0));
      expect(copy.customDec, equals(2.0));
    });

    test('equality', () {
      final a = SlewNode(id: 's', customRa: 1.0, customDec: 2.0);
      final b = SlewNode(id: 's', customRa: 1.0, customDec: 2.0);
      expect(a, equals(b));
      expect(a, isNot(equals(b.copyWith(customRa: 1.5))));
    });
  });

  group('CenterNode', () {
    test('node_type_and_required_devices', () {
      final n = CenterNode();
      expect(n.nodeType, equals('CenterTarget'));
      expect(n.iconName, equals('crosshair'));
      expect(n.requiredDevices, equals({DeviceType.mount, DeviceType.camera}));
    });

    test('default_values_match_documented_defaults', () {
      final n = CenterNode();
      expect(n.accuracyArcsec, equals(5.0));
      expect(n.maxAttempts, equals(5));
      expect(n.useTargetCoords, isTrue);
      expect(n.customRa, isNull);
      expect(n.customDec, isNull);
      expect(n.exposureDuration, equals(5.0));
      expect(n.filter, isNull);
    });

    test('copyWith_each_field', () {
      final n = CenterNode();
      expect(n.copyWith(accuracyArcsec: 2.0).accuracyArcsec, equals(2.0));
      expect(n.copyWith(maxAttempts: 10).maxAttempts, equals(10));
      expect(n.copyWith(useTargetCoords: false).useTargetCoords, isFalse);
      expect(n.copyWith(customRa: 1.0).customRa, equals(1.0));
      expect(n.copyWith(customDec: 2.0).customDec, equals(2.0));
      expect(n.copyWith(exposureDuration: 10.0).exposureDuration, equals(10.0));
      expect(n.copyWith(filter: 'L').filter, equals('L'));
      expect(n.copyWith(), equals(n));
    });
  });

  group('AutofocusNode', () {
    test('node_type_and_required_devices', () {
      final n = AutofocusNode();
      expect(n.nodeType, equals('Autofocus'));
      expect(n.iconName, equals('focus'));
      expect(
        n.requiredDevices,
        equals({DeviceType.camera, DeviceType.focuser}),
      );
    });

    test('defaults_match_settings_path', () {
      final n = AutofocusNode();
      expect(n.method, equals(AutofocusMethod.vCurve));
      expect(n.stepSize, equals(100));
      expect(n.stepsOut, equals(7));
      expect(n.exposuresPerPoint, equals(1));
      expect(n.exposureDuration, equals(3.0));
      expect(n.useSettingsDefaults, isTrue);
      expect(n.maxDurationSecs, equals(600.0));
    });

    test('copyWith_each_field', () {
      final n = AutofocusNode();
      expect(
        n.copyWith(method: AutofocusMethod.hyperbolic).method,
        equals(AutofocusMethod.hyperbolic),
      );
      expect(n.copyWith(stepSize: 50).stepSize, equals(50));
      expect(n.copyWith(stepsOut: 9).stepsOut, equals(9));
      expect(n.copyWith(exposuresPerPoint: 3).exposuresPerPoint, equals(3));
      expect(n.copyWith(exposureDuration: 5.0).exposureDuration, equals(5.0));
      expect(
        n.copyWith(useSettingsDefaults: false).useSettingsDefaults,
        isFalse,
      );
      expect(n.copyWith(maxDurationSecs: 900.0).maxDurationSecs, equals(900.0));
      expect(n.copyWith(), equals(n));
    });
  });

  group('DitherNode', () {
    test('node_type_and_required_devices', () {
      final n = DitherNode();
      expect(n.nodeType, equals('Dither'));
      expect(n.iconName, equals('shuffle'));
      expect(n.requiredDevices, equals({DeviceType.guider}));
    });

    test('copyWith_each_field', () {
      final n = DitherNode();
      expect(n.copyWith(pixels: 10.0).pixels, equals(10.0));
      expect(n.copyWith(settleTime: 60.0).settleTime, equals(60.0));
      expect(n.copyWith(settlePixels: 2.0).settlePixels, equals(2.0));
      expect(n.copyWith(settleTimeout: 240.0).settleTimeout, equals(240.0));
      expect(n.copyWith(raOnly: true).raOnly, isTrue);
      expect(
        n.copyWith(pattern: DitherPattern.grid).pattern,
        equals(DitherPattern.grid),
      );
      expect(n.copyWith(gridSize: 5).gridSize, equals(5));
      expect(n.copyWith(), equals(n));
    });

    test('equality_includes_pattern_and_grid_size', () {
      final a = DitherNode(id: 'd', pattern: DitherPattern.grid, gridSize: 4);
      final b = DitherNode(id: 'd', pattern: DitherPattern.grid, gridSize: 4);
      expect(a, equals(b));
      expect(a, isNot(equals(b.copyWith(gridSize: 5))));
    });
  });

  group('StartGuidingNode', () {
    test('node_type_and_required_devices', () {
      final n = StartGuidingNode();
      expect(n.nodeType, equals('StartGuiding'));
      expect(n.requiredDevices, equals({DeviceType.guider}));
    });

    test('copyWith_each_field', () {
      final n = StartGuidingNode();
      expect(n.copyWith(settlePixels: 3.0).settlePixels, equals(3.0));
      expect(n.copyWith(settleTime: 20.0).settleTime, equals(20.0));
      expect(n.copyWith(settleTimeout: 120.0).settleTimeout, equals(120.0));
      expect(n.copyWith(autoSelectStar: false).autoSelectStar, isFalse);
      expect(n.copyWith(), equals(n));
    });
  });

  group('StopGuidingNode', () {
    test('node_type_and_required_devices', () {
      final n = StopGuidingNode();
      expect(n.nodeType, equals('StopGuiding'));
      expect(n.iconName, equals('x-circle'));
      expect(n.requiredDevices, equals({DeviceType.guider}));
    });

    test('copyWith_base_fields_only', () {
      // StopGuidingNode has no own fields.
      final n = StopGuidingNode(name: 'orig');
      expect(n.copyWith(name: 'new').name, equals('new'));
      expect(n.copyWith(), equals(n));
    });
  });

  group('FilterChangeNode', () {
    test('node_type_and_required_devices', () {
      final n = FilterChangeNode(filterName: 'L');
      expect(n.nodeType, equals('ChangeFilter'));
      expect(n.requiredDevices, equals({DeviceType.filterWheel}));
    });

    test('copyWith_each_field', () {
      final n = FilterChangeNode(filterName: 'L');
      expect(n.copyWith(filterName: 'Ha').filterName, equals('Ha'));
      expect(n.copyWith(filterPosition: 3).filterPosition, equals(3));
      expect(n.copyWith(), equals(n));
    });
  });

  group('CoolCameraNode', () {
    test('node_type_and_required_devices', () {
      final n = CoolCameraNode();
      expect(n.nodeType, equals('CoolCamera'));
      expect(n.requiredDevices, equals({DeviceType.camera}));
    });

    test('copyWith_each_field', () {
      final n = CoolCameraNode();
      expect(n.copyWith(targetTemp: -20.0).targetTemp, equals(-20.0));
      expect(n.copyWith(durationMins: 5.0).durationMins, equals(5.0));
      expect(n.copyWith(), equals(n));
    });
  });

  group('WarmCameraNode', () {
    test('node_type_and_required_devices', () {
      final n = WarmCameraNode();
      expect(n.nodeType, equals('WarmCamera'));
      expect(n.requiredDevices, equals({DeviceType.camera}));
    });

    test('copyWith_each_field', () {
      final n = WarmCameraNode();
      expect(n.copyWith(ratePerMin: 5.0).ratePerMin, equals(5.0));
      expect(n.copyWith(targetTemp: 15.0).targetTemp, equals(15.0));
      expect(n.copyWith(), equals(n));
    });
  });

  group('RotatorNode', () {
    test('node_type_and_required_devices', () {
      final n = RotatorNode();
      expect(n.nodeType, equals('MoveRotator'));
      expect(n.requiredDevices, equals({DeviceType.rotator}));
    });

    test('copyWith_each_field', () {
      final n = RotatorNode();
      expect(n.copyWith(targetAngle: 90.0).targetAngle, equals(90.0));
      expect(n.copyWith(relative: true).relative, isTrue);
      expect(n.copyWith(), equals(n));
    });
  });

  // ParkNode / UnparkNode
  group('ParkNode', () {
    test('node_type_and_required_devices', () {
      final n = ParkNode();
      expect(n.nodeType, equals('Park'));
      expect(n.requiredDevices, equals({DeviceType.mount}));
    });

    test('copyWith_no_args', () {
      final n = ParkNode(name: 'p');
      expect(n.copyWith(), equals(n));
    });
  });

  group('UnparkNode', () {
    test('node_type_and_required_devices', () {
      final n = UnparkNode();
      expect(n.nodeType, equals('Unpark'));
      expect(n.requiredDevices, equals({DeviceType.mount}));
    });

    test('copyWith_no_args', () {
      final n = UnparkNode(name: 'u');
      expect(n.copyWith(), equals(n));
    });
  });

  group('WaitTimeNode', () {
    test('node_type_pin', () {
      final n = WaitTimeNode();
      expect(n.nodeType, equals('WaitForTime'));
      expect(n.requiredDevices, isEmpty);
    });

    test('copyWith_each_field', () {
      final n = WaitTimeNode();
      final dt = DateTime.utc(2026, 5, 25, 20, 0, 0);
      expect(n.copyWith(waitUntil: dt).waitUntil, equals(dt));
      expect(
        n.copyWith(waitForTwilight: TwilightType.astronomical).waitForTwilight,
        equals(TwilightType.astronomical),
      );
      expect(n.copyWith(), equals(n));
    });

    test('equality_includes_wait_until', () {
      final dt = DateTime.utc(2026, 1, 1);
      final a = WaitTimeNode(id: 'w', waitUntil: dt);
      final b = WaitTimeNode(id: 'w', waitUntil: dt);
      expect(a, equals(b));
      expect(
        a,
        isNot(
          equals(b.copyWith(waitUntil: dt.add(const Duration(seconds: 1)))),
        ),
      );
    });
  });

  group('DelayNode', () {
    test('node_type_pin', () {
      final n = DelayNode();
      expect(n.nodeType, equals('Delay'));
      expect(n.iconName, equals('timer'));
    });

    test('copyWith_seconds', () {
      final n = DelayNode();
      expect(n.copyWith(seconds: 30.0).seconds, equals(30.0));
      expect(n.copyWith(), equals(n));
    });
  });

  group('ScriptNode', () {
    test('node_type_pin', () {
      final n = ScriptNode();
      expect(n.nodeType, equals('RunScript'));
    });

    test('copyWith_each_field', () {
      final n = ScriptNode();
      expect(
        n.copyWith(scriptPath: '/tmp/x.sh').scriptPath,
        equals('/tmp/x.sh'),
      );
      expect(
        n.copyWith(arguments: ['-v', 'arg']).arguments,
        equals(['-v', 'arg']),
      );
      expect(n.copyWith(timeoutSecs: 60).timeoutSecs, equals(60));
      expect(n.copyWith(), equals(n));
    });

    test('equality_includes_arguments_list', () {
      final a = ScriptNode(id: 's', arguments: const ['x']);
      final b = ScriptNode(id: 's', arguments: const ['x']);
      expect(a, equals(b));
      expect(a, isNot(equals(b.copyWith(arguments: const ['y']))));
    });
  });

  // OpenDomeNode / CloseDomeNode / ParkDomeNode
  group('OpenDomeNode', () {
    test('node_type_and_required_devices', () {
      final n = OpenDomeNode();
      expect(n.nodeType, equals('OpenDome'));
      expect(n.requiredDevices, equals({DeviceType.dome}));
    });

    test('copyWith_shutter_only', () {
      final n = OpenDomeNode();
      expect(n.copyWith(shutterOnly: true).shutterOnly, isTrue);
      expect(n.copyWith(), equals(n));
    });
  });

  group('CloseDomeNode', () {
    test('node_type_and_required_devices', () {
      final n = CloseDomeNode();
      expect(n.nodeType, equals('CloseDome'));
      expect(n.requiredDevices, equals({DeviceType.dome}));
    });

    test('copyWith_shutter_only', () {
      final n = CloseDomeNode();
      expect(n.copyWith(shutterOnly: true).shutterOnly, isTrue);
      expect(n.copyWith(), equals(n));
    });
  });

  group('ParkDomeNode', () {
    test('node_type_and_required_devices', () {
      final n = ParkDomeNode();
      expect(n.nodeType, equals('ParkDome'));
      expect(n.requiredDevices, equals({DeviceType.dome}));
    });

    test('copyWith_shutter_only', () {
      final n = ParkDomeNode();
      expect(n.copyWith(shutterOnly: true).shutterOnly, isTrue);
      expect(n.copyWith(), equals(n));
    });
  });

  group('PolarAlignmentNode', () {
    test('node_type_and_required_devices', () {
      final n = PolarAlignmentNode();
      expect(n.nodeType, equals('PolarAlignment'));
      expect(n.requiredDevices, equals({DeviceType.camera, DeviceType.mount}));
    });

    test('defaults_match_documented_values', () {
      final n = PolarAlignmentNode();
      expect(n.exposureDuration, equals(2.0));
      expect(n.binning, equals(2));
      expect(n.startAltitude, equals(45.0));
      expect(n.rotationStep, equals(20.0));
      expect(n.gain, isNull);
      expect(n.offset, isNull);
      expect(n.startFromCurrent, isTrue);
      expect(n.isNorth, isTrue);
      expect(n.manualSlew, isFalse);
    });

    test('copyWith_each_field', () {
      final n = PolarAlignmentNode();
      expect(n.copyWith(exposureDuration: 5.0).exposureDuration, equals(5.0));
      expect(n.copyWith(binning: 1).binning, equals(1));
      expect(n.copyWith(startAltitude: 60.0).startAltitude, equals(60.0));
      expect(n.copyWith(rotationStep: 30.0).rotationStep, equals(30.0));
      expect(n.copyWith(gain: 200).gain, equals(200));
      expect(n.copyWith(offset: 30).offset, equals(30));
      expect(n.copyWith(startFromCurrent: false).startFromCurrent, isFalse);
      expect(n.copyWith(isNorth: false).isNorth, isFalse);
      expect(n.copyWith(manualSlew: true).manualSlew, isTrue);
      expect(n.copyWith(), equals(n));
    });
  });

  // OpenCoverNode / CloseCoverNode
  group('OpenCoverNode', () {
    test('node_type_and_required_devices', () {
      final n = OpenCoverNode();
      expect(n.nodeType, equals('OpenCover'));
      expect(n.requiredDevices, equals({DeviceType.coverCalibrator}));
    });

    test('copyWith_timeout', () {
      final n = OpenCoverNode();
      expect(n.copyWith(timeoutSecs: 120).timeoutSecs, equals(120));
      expect(n.copyWith(), equals(n));
    });
  });

  group('CloseCoverNode', () {
    test('node_type_and_required_devices', () {
      final n = CloseCoverNode();
      expect(n.nodeType, equals('CloseCover'));
      expect(n.requiredDevices, equals({DeviceType.coverCalibrator}));
    });

    test('copyWith_timeout', () {
      final n = CloseCoverNode();
      expect(n.copyWith(timeoutSecs: 120).timeoutSecs, equals(120));
      expect(n.copyWith(), equals(n));
    });
  });

  // CalibratorOnNode / CalibratorOffNode
  group('CalibratorOnNode', () {
    test('node_type_and_required_devices', () {
      final n = CalibratorOnNode();
      expect(n.nodeType, equals('CalibratorOn'));
      expect(n.requiredDevices, equals({DeviceType.coverCalibrator}));
    });

    test('copyWith_each_field', () {
      final n = CalibratorOnNode();
      expect(n.copyWith(brightness: 255).brightness, equals(255));
      expect(n.copyWith(timeoutSecs: 60).timeoutSecs, equals(60));
      expect(n.copyWith(), equals(n));
    });
  });

  group('CalibratorOffNode', () {
    test('node_type_and_required_devices', () {
      final n = CalibratorOffNode();
      expect(n.nodeType, equals('CalibratorOff'));
      expect(n.requiredDevices, equals({DeviceType.coverCalibrator}));
    });

    test('copyWith_timeout', () {
      final n = CalibratorOffNode();
      expect(n.copyWith(timeoutSecs: 60).timeoutSecs, equals(60));
      expect(n.copyWith(), equals(n));
    });
  });

  group('PluginInstructionNode', () {
    test('node_type_and_icon_pin', () {
      final n = PluginInstructionNode(
        pluginId: 'com.example.x',
        nodeTypeId: 'do.thing',
      );
      expect(n.nodeType, equals('PluginNode'));
      // iconName forwards from iconHint — pin BOTH the default ('puzzle')
      // and the override behaviour.
      expect(n.iconName, equals('puzzle'));
      expect(n.category, equals(NodeCategory.instruction));
      expect(n.requiredDevices, isEmpty);
    });

    test('default_config_json_is_empty_object_literal', () {
      // configJson defaults to the literal `'{}'`, not null, so a
      // freshly-dropped palette node round-trips through jsonDecode
      // cleanly.
      final n = PluginInstructionNode(pluginId: 'a', nodeTypeId: 'b');
      expect(n.configJson, equals('{}'));
    });

    test('registration_key_format', () {
      final n = PluginInstructionNode(pluginId: 'a', nodeTypeId: 'b');
      expect(n.registrationKey, equals('a::b'));
    });

    test('icon_hint_overrides_iconName', () {
      final n = PluginInstructionNode(
        pluginId: 'a',
        nodeTypeId: 'b',
        iconHint: 'star',
      );
      expect(n.iconName, equals('star'));
    });

    test('copyWith_each_field', () {
      final n = PluginInstructionNode(pluginId: 'a', nodeTypeId: 'b');
      expect(n.copyWith(pluginId: 'x').pluginId, equals('x'));
      expect(n.copyWith(nodeTypeId: 'y').nodeTypeId, equals('y'));
      expect(n.copyWith(configJson: '{"k":1}').configJson, equals('{"k":1}'));
      expect(n.copyWith(timeoutSecs: 30).timeoutSecs, equals(30));
      expect(n.copyWith(pluginName: 'name').pluginName, equals('name'));
      expect(n.copyWith(iconHint: 'star').iconHint, equals('star'));
      expect(n.copyWith(), equals(n));
    });

    test('equality_via_props', () {
      final a = PluginInstructionNode(id: 'p', pluginId: 'a', nodeTypeId: 'b');
      final b = PluginInstructionNode(id: 'p', pluginId: 'a', nodeTypeId: 'b');
      expect(a, equals(b));
      expect(a, isNot(equals(b.copyWith(configJson: '{"x":1}'))));
    });
  });

  // Shared base-class behaviour (SequenceNode)
  group('SequenceNode (base)', () {
    test('auto_generates_uuid_when_id_omitted', () {
      final a = DelayNode();
      final b = DelayNode();
      expect(a.id, isNotEmpty);
      expect(b.id, isNotEmpty);
      expect(a.id, isNot(equals(b.id)));
    });

    test('comment_field_round_trips_through_copyWith', () {
      final n = DelayNode(comment: 'hello');
      expect(n.comment, equals('hello'));
      expect(n.copyWith(comment: 'updated').comment, equals('updated'));
      expect(n.copyWith().comment, equals('hello'));
    });

    test('child_ids_default_to_empty_list', () {
      final n = DelayNode();
      expect(n.childIds, isEmpty);
    });

    test('props_include_all_base_fields', () {
      // Two nodes differing only in orderIndex must NOT be equal.
      final a = DelayNode(id: 'd', orderIndex: 0);
      final b = DelayNode(id: 'd', orderIndex: 1);
      expect(a, isNot(equals(b)));
    });
  });
}
