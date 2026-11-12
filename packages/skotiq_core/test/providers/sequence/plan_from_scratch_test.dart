// Building a target top to bottom from the palette.
//
// The walk-through added a Target, then Take exposures, Slew to target and
// Start guiding. Each "+" lands after the selection, which follows the newest
// step, so the slew and the guider start ran after the frames and the
// pre-flight said nothing about it. The row kept saying "Target" after the
// target was named M34.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/models/sequence/validation/rules/target_rules.dart';

void main() {
  late ProviderContainer container;
  CurrentSequenceNotifier editor() =>
      container.read(currentSequenceProvider.notifier);
  Sequence sequence() => container.read(currentSequenceProvider)!;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  /// Insert [node] after the current selection, then select it, as a palette
  /// "+" does.
  String? selection;
  void add(SequenceNode node) {
    editor().insertNewNode(node, parentId: selection);
    selection = node.id;
  }

  List<String> stepsOf(String targetId) => [
    for (final id in sequence().nodes[targetId]!.childIds)
      sequence().nodes[id]!.name,
  ];

  setUp(() => selection = null);

  group('a new step that aims or readies the rig', () {
    test('goes ahead of the frames when added after them', () {
      editor().createSequence();
      add(
        TargetHeaderNode(
          id: 't',
          targetName: 'M34',
          raHours: 2.7,
          decDegrees: 42.8,
        ),
      );
      add(ExposureNode(name: 'Lights', durationSecs: 60, count: 10));
      add(SlewNode(name: 'Slew'));
      add(StartGuidingNode(name: 'Guide'));

      expect(stepsOf('t'), ['Slew', 'Guide', 'Lights']);
    });

    test('goes ahead of a block that holds frames', () {
      editor().createSequence();
      add(
        TargetHeaderNode(
          id: 't',
          targetName: 'M34',
          raHours: 2.7,
          decDegrees: 42.8,
        ),
      );
      final block = InstructionSetNode(name: 'L block');
      add(block);
      selection = block.id;
      add(ExposureNode(name: 'Lights', durationSecs: 60, count: 10));
      selection = 't';
      add(CenterNode(name: 'Center'));

      expect(stepsOf('t'), ['Center', 'L block']);
    });

    test('stays where it was added when one already leads the frames', () {
      editor().createSequence();
      add(
        TargetHeaderNode(
          id: 't',
          targetName: 'M34',
          raHours: 2.7,
          decDegrees: 42.8,
        ),
      );
      add(SlewNode(name: 'Slew'));
      add(AutofocusNode(name: 'Focus'));
      add(ExposureNode(name: 'L', durationSecs: 60, count: 10));
      add(AutofocusNode(name: 'Refocus'));
      add(ExposureNode(name: 'R', durationSecs: 60, count: 10));
      add(SlewNode(name: 'Next panel'));

      expect(stepsOf('t'), [
        'Slew',
        'Focus',
        'L',
        'Refocus',
        'R',
        'Next panel',
      ]);
    });

    test('stays where it was put when given a position', () {
      editor().createSequence();
      add(
        TargetHeaderNode(
          id: 't',
          targetName: 'M34',
          raHours: 2.7,
          decDegrees: 42.8,
        ),
      );
      add(ExposureNode(name: 'Lights', durationSecs: 60, count: 10));
      editor().insertNewNode(SlewNode(name: 'Slew'), parentId: 't', index: 1);

      expect(stepsOf('t'), ['Lights', 'Slew']);
    });
  });

  test('a closing step still goes after the frames', () {
    editor().createSequence();
    add(
      TargetHeaderNode(
        id: 't',
        targetName: 'M34',
        raHours: 2.7,
        decDegrees: 42.8,
      ),
    );
    add(ExposureNode(name: 'Lights', durationSecs: 60, count: 10));
    add(ParkNode(name: 'Park'));

    expect(stepsOf('t'), ['Lights', 'Park']);
  });

  test('Move up and Move down shift a step among its siblings', () {
    editor().createSequence();
    add(
      TargetHeaderNode(
        id: 't',
        targetName: 'M34',
        raHours: 2.7,
        decDegrees: 42.8,
      ),
    );
    final lights = ExposureNode(name: 'Lights', durationSecs: 60, count: 10);
    add(lights);
    add(ParkNode(name: 'Park'));

    expect(editor().shiftNode(lights.id, 1), isTrue);
    expect(stepsOf('t'), ['Park', 'Lights']);
    expect(editor().shiftNode(lights.id, 1), isFalse);
    expect(editor().shiftNode(lights.id, -1), isTrue);
    expect(stepsOf('t'), ['Lights', 'Park']);
    expect(editor().shiftNode(lights.id, -1), isFalse);
  });

  group('a target row', () {
    test('takes the name typed for the target', () {
      editor().createSequence();
      final target = TargetHeaderNode(
        id: 't',
        targetName: 'New Target',
        raHours: 0,
        decDegrees: 0,
      );
      add(target);
      for (final typed in ['M', 'M3', 'M34']) {
        final current = sequence().nodes['t']! as TargetHeaderNode;
        editor().updateNode(current.copyWith(targetName: typed));
      }
      expect(sequence().nodes['t']!.name, 'M34');
    });

    test('a filter step named for its filter follows a new filter', () {
      editor().createSequence();
      final change = FilterChangeNode(id: 'f', filterName: 'Lum');
      add(change);
      editor().updateNode(change.copyWith(filterName: 'L'));
      expect(sequence().nodes['f']!.name, 'Filter: L');

      final renamed = sequence().nodes['f']! as FilterChangeNode;
      editor().updateNode(renamed.copyWith(name: 'Luminance'));
      editor().updateNode(
        (sequence().nodes['f']! as FilterChangeNode).copyWith(filterName: 'R'),
      );
      expect(sequence().nodes['f']!.name, 'Luminance');
    });

    test('takes the typed name when keystrokes outrun the editor', () {
      editor().createSequence();
      final target = TargetHeaderNode(
        id: 't',
        targetName: 'New Target',
        raHours: 0,
        decDegrees: 0,
      );
      add(target);
      // Each keystroke's closure holds the node as it was drawn: the first
      // copy, before any keystroke landed.
      for (final typed in ['M', 'M3', 'M34']) {
        editor().editNode<TargetHeaderNode>(
          't',
          (current) => current.copyWith(targetName: typed),
        );
      }
      expect(sequence().nodes['t']!.name, 'M34');
    });

    test('keeps a name the operator gave it', () {
      editor().createSequence();
      add(
        TargetHeaderNode(
          id: 't',
          name: 'Autumn galaxy',
          targetName: 'M33',
          raHours: 1.56,
          decDegrees: 30.66,
        ),
      );
      final current = sequence().nodes['t']! as TargetHeaderNode;
      editor().updateNode(current.copyWith(targetName: 'M31'));
      expect(sequence().nodes['t']!.name, 'Autumn galaxy');
    });
  });

  group('the order check', () {
    List<ValidationIssue> check() =>
        CaptureBeforeAimRule().validate(sequence());

    test('flags a slew that runs after the frames', () {
      editor().createSequence();
      add(
        TargetHeaderNode(
          id: 't',
          targetName: 'M34',
          raHours: 2.7,
          decDegrees: 42.8,
        ),
      );
      add(ExposureNode(name: 'Lights', durationSecs: 60, count: 10));
      final slew = SlewNode(name: 'Slew');
      editor().insertNewNode(slew, parentId: 't', index: 1);

      final issues = check();
      expect(issues, hasLength(1));
      expect(issues.single.affectedNodeId, slew.id);
      expect(issues.single.severity, ValidationSeverity.warning);
      expect(issues.single.description, contains('"Slew" runs after "Lights"'));
    });

    test('accepts a re-center after the target was aimed first', () {
      editor().createSequence();
      add(
        TargetHeaderNode(
          id: 't',
          targetName: 'M34',
          raHours: 2.7,
          decDegrees: 42.8,
        ),
      );
      add(SlewNode(name: 'Slew'));
      add(ExposureNode(name: 'Lights', durationSecs: 60, count: 10));
      editor().insertNewNode(
        CenterNode(name: 'Re-center'),
        parentId: 't',
        index: 2,
      );

      expect(check(), isEmpty);
    });

    test('leaves a target that never aims to the mount check', () {
      editor().createSequence();
      add(
        TargetHeaderNode(
          id: 't',
          targetName: 'M34',
          raHours: 2.7,
          decDegrees: 42.8,
        ),
      );
      add(ExposureNode(name: 'Lights', durationSecs: 60, count: 10));

      expect(check(), isEmpty);
    });
  });
}
