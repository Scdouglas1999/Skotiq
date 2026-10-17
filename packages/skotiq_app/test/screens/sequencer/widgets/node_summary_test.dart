// PURE unit tests for the at-a-glance summary classifier (`node_summary.dart`,
// C1). No widget pump: these exercise the dependency-free `nodeSummary` /
// `summaryHasInlineEdits` logic directly.
//
// Three things are pinned here:
//   1. Per-type fragment shape — each major node renders the expected
//      Static/Editable fragments with the right kinds + display values.
//   2. EXHAUSTIVENESS — one instance of EVERY concrete subtype produces a
//      non-empty summary and never throws. This locks the "summary for every
//      node type" contract: a new subtype that forgets a summary fails the
//      sealed `switch` at compile time AND would trip this test.
//   3. CLASSIFICATION — `summaryHasInlineEdits` is true for exactly the set of
//      node types that expose a single safe inline-editable scalar/enum/pick,
//      and false for everything else (coordinates, watchdogs, terminal
//      actions, multi-field config).

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_summary.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Matcher: the summary contains an [EditableFragment] of [kind] showing
/// [value]. Matches on the semantic identity (kind + display value) and is
/// deliberately agnostic to the optional lead icon, which is a render-layer
/// affordance rather than part of the edit contract.
Matcher _hasEditable(InlineEditKind kind, String value) => contains(
      predicate<SummaryFragment>(
        (f) =>
            f is EditableFragment && f.kind == kind && f.displayValue == value,
        'an EditableFragment($kind, "$value")',
      ),
    );

/// All 37 concrete [SequenceNode] subtypes, one instance each. Used by the
/// exhaustiveness guard. Subtypes with required constructor fields get the
/// minimal valid arguments; everything else uses defaults.
List<SequenceNode> _oneOfEverySubtype() => <SequenceNode>[
      TargetHeaderNode(targetName: 'M31', raHours: 0.71, decDegrees: 41.27),
      LoopNode(),
      ParallelNode(),
      ConditionalNode(),
      RecoveryNode(),
      InstructionSetNode(),
      SlewNode(),
      CenterNode(),
      ExposureNode(),
      AutofocusNode(),
      DitherNode(),
      StartGuidingNode(),
      StopGuidingNode(),
      FilterChangeNode(filterName: 'Ha'),
      CoolCameraNode(),
      WarmCameraNode(),
      RotatorNode(),
      ParkNode(),
      UnparkNode(),
      WaitTimeNode(),
      DelayNode(),
      NotificationNode(),
      ScriptNode(),
      MeridianFlipNode(),
      OpenDomeNode(),
      CloseDomeNode(),
      ParkDomeNode(),
      PolarAlignmentNode(),
      OpenCoverNode(),
      CloseCoverNode(),
      CalibratorOnNode(),
      CalibratorOffNode(),
      TargetSchedulerNode(),
      SmartExposureNode(),
      LiveStackingNode(),
      SciencePhotometryNode(),
      PluginInstructionNode(pluginId: 'com.example.x', nodeTypeId: 'x.notify'),
    ];

void main() {
  group('nodeSummary — per-type fragment shape', () {
    test(
        'ExposureNode emits editable count / duration / filter / gain / binning '
        'fragments', () {
      final node = ExposureNode(
        count: 5,
        durationSecs: 120,
        filter: 'Ha',
        gain: 100,
        binning: BinningMode.two,
      );

      final fragments = nodeSummary(node);

      expect(fragments, _hasEditable(InlineEditKind.exposureCount, '5'));
      expect(fragments, _hasEditable(InlineEditKind.exposureDuration, '120s'));
      expect(fragments, _hasEditable(InlineEditKind.exposureFilter, 'Ha'));
      // Gain (when overridden) and binning are editable chips too.
      expect(fragments, _hasEditable(InlineEditKind.gain, 'gain 100'));
      expect(fragments, _hasEditable(InlineEditKind.binning, '2x2'));
    });

    test(
        'ExposureNode without a gain override emits no gain fragment, but '
        'binning is always editable', () {
      final node = ExposureNode(
        count: 2,
        durationSecs: 60,
        filter: null,
        gain: null,
        binning: BinningMode.three,
      );

      final fragments = nodeSummary(node);

      final gainFrags = fragments
          .whereType<EditableFragment>()
          .where((f) => f.kind == InlineEditKind.gain);
      expect(gainFrags, isEmpty);
      expect(fragments, _hasEditable(InlineEditKind.binning, '3x3'));
    });

    test('ExposureNode with fractional duration keeps one decimal', () {
      final node = ExposureNode(count: 3, durationSecs: 1.5, filter: null);
      expect(
        nodeSummary(node),
        _hasEditable(InlineEditKind.exposureDuration, '1.5s'),
      );
    });

    test('ExposureNode without a filter emits no filter fragment', () {
      final node = ExposureNode(count: 2, durationSecs: 60, filter: null);
      final filterFrags = nodeSummary(node)
          .whereType<EditableFragment>()
          .where((f) => f.kind == InlineEditKind.exposureFilter);
      expect(filterFrags, isEmpty);
    });

    test('SmartExposureNode in loop mode shows "1 each · looping"', () {
      final node = SmartExposureNode(
        loopUntilStopped: true,
        plans: const [
          FilterPlan(filterName: 'L', count: 192, durationSecs: 60),
          FilterPlan(filterName: 'R', count: 96, durationSecs: 120),
          FilterPlan(filterName: 'G', count: 96, durationSecs: 120),
          FilterPlan(filterName: 'B', count: 96, durationSecs: 120),
        ],
      );
      final texts = nodeSummary(node)
          .whereType<StaticFragment>()
          .map((f) => f.text)
          .toList();
      // Round-robin filter list, "1 each", and "looping" — NOT the fixed
      // 192/96 counts.
      expect(texts, contains('L·R·G·B'));
      expect(texts, contains('1 each'));
      expect(texts, contains('looping'));
      expect(
        texts.any((t) => t.contains('192') || t.contains('96')),
        isFalse,
        reason: 'loop mode must not show the per-filter counts',
      );
    });

    test('SmartExposureNode without loop mode lists per-filter count×duration',
        () {
      final node = SmartExposureNode(
        plans: const [
          FilterPlan(filterName: 'L', count: 10, durationSecs: 60),
        ],
      );
      final texts = nodeSummary(node)
          .whereType<StaticFragment>()
          .map((f) => f.text)
          .toList();
      expect(texts.any((t) => t.contains('10×60s')), isTrue);
      expect(texts, isNot(contains('looping')));
    });

    test('LoopNode (count) emits an editable iteration count', () {
      final node = LoopNode(
        conditionType: LoopConditionType.count,
        repeatCount: 3,
      );
      expect(
        nodeSummary(node),
        _hasEditable(InlineEditKind.loopIterations, '3'),
      );
    });

    test('LoopNode (forever) is all static — no editable fragments', () {
      final node = LoopNode(conditionType: LoopConditionType.forever);
      expect(nodeSummary(node).whereType<EditableFragment>(), isEmpty);
      expect(nodeSummary(node), isNotEmpty);
    });

    test('FilterChangeNode emits an editable filterChange fragment', () {
      final node = FilterChangeNode(filterName: 'OIII');
      expect(
        nodeSummary(node),
        _hasEditable(InlineEditKind.filterChange, 'OIII'),
      );
    });

    test('DelayNode emits an editable delaySeconds fragment', () {
      final node = DelayNode(seconds: 30);
      expect(
        nodeSummary(node),
        _hasEditable(InlineEditKind.delaySeconds, '30s'),
      );
    });

    test('CenterNode emits an editable centerTolerance fragment', () {
      final node = CenterNode(accuracyArcsec: 3);
      expect(
        nodeSummary(node),
        _hasEditable(InlineEditKind.centerTolerance, '3"'),
      );
    });

    test('SlewNode / MeridianFlipNode / ParkNode are entirely static', () {
      for (final node in <SequenceNode>[
        SlewNode(),
        MeridianFlipNode(),
        ParkNode(),
      ]) {
        expect(
          nodeSummary(node).whereType<EditableFragment>(),
          isEmpty,
          reason: '${node.runtimeType} must expose no inline-editable fragment',
        );
        expect(
          nodeSummary(node),
          isNotEmpty,
          reason: '${node.runtimeType} must still render a summary',
        );
      }
    });
  });

  group('nodeSummary — exhaustiveness guard', () {
    test('every concrete subtype produces a non-empty summary, never throws',
        () {
      for (final node in _oneOfEverySubtype()) {
        expect(
          () => nodeSummary(node),
          returnsNormally,
          reason: '${node.runtimeType} must not throw from nodeSummary',
        );
        expect(
          nodeSummary(node),
          isNotEmpty,
          reason: '${node.runtimeType} must render at least one fragment',
        );
      }
    });

    test('the guard covers the full sealed hierarchy (37 subtypes)', () {
      // A trip-wire: if the model grows a subtype, the sealed `switch` in
      // nodeSummary fails to compile first; this count keeps the guard list
      // itself honest so we never silently drop a type from coverage.
      final types = _oneOfEverySubtype().map((n) => n.runtimeType).toSet();
      expect(types.length, _oneOfEverySubtype().length);
      expect(types.length, 37);
    });
  });

  group('summaryHasInlineEdits — classification', () {
    final editable = <SequenceNode>[
      ExposureNode(),
      LoopNode(conditionType: LoopConditionType.count),
      FilterChangeNode(filterName: 'Ha'),
      DelayNode(),
      CenterNode(),
      DitherNode(),
      CoolCameraNode(),
      // Only in override mode: with `useSettingsDefaults` on, the method the
      // chip edits is discarded by the executor, so no chip is offered.
      AutofocusNode(useSettingsDefaults: false),
    ];

    final notEditable = <SequenceNode>[
      AutofocusNode(),
      SlewNode(),
      MeridianFlipNode(),
      ParkNode(),
      ConditionalNode(),
      RecoveryNode(),
      WarmCameraNode(),
      RotatorNode(),
      NotificationNode(),
      ScriptNode(),
    ];

    for (final node in editable) {
      test('${node.runtimeType} is classified inline-editable', () {
        expect(summaryHasInlineEdits(node), isTrue);
      });
    }

    for (final node in notEditable) {
      test('${node.runtimeType} is classified NOT inline-editable', () {
        expect(summaryHasInlineEdits(node), isFalse);
      });
    }

    test('summaryHasInlineEdits agrees with the fragment list', () {
      for (final node in [...editable, ...notEditable]) {
        final hasEditable = nodeSummary(node).any((f) => f is EditableFragment);
        expect(summaryHasInlineEdits(node), hasEditable);
      }
    });
  });
}
