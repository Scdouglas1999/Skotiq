import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/models/sequence/template_snippet.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';
import 'package:skotiq_core/src/providers/template_snippet_provider.dart';

ProviderContainer _newContainer() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'custom snippet round-trip preserves canonical node fields and types',
    () {
      final waitUntil = DateTime.utc(2026, 7, 14, 2, 30);
      final nodes = <SequenceNode>[
        WarmCameraNode(
          id: 'warm',
          parentId: 'root',
          ratePerMin: 0.75,
          targetTemp: 12.5,
          comment: 'Avoid dew shock',
        ),
        DitherNode(
          id: 'dither',
          parentId: 'root',
          pixels: 7.5,
          settlePixels: 0.8,
          settleTime: 12,
          settleTimeout: 95,
          raOnly: true,
          pattern: DitherPattern.grid,
          gridSize: 5,
        ),
        RotatorNode(
          id: 'rotator',
          parentId: 'root',
          targetAngle: 137.2,
          relative: true,
        ),
        WaitTimeNode(
          id: 'wait',
          parentId: 'root',
          waitUntil: waitUntil,
          waitForTwilight: TwilightType.astronomical,
        ),
        ScriptNode(
          id: 'script',
          parentId: 'root',
          scriptPath: '/opt/skotiq/preflight.sh',
          arguments: const ['--safe', 'M31'],
          timeoutSecs: 47,
        ),
        PolarAlignmentNode(
          id: 'polar',
          parentId: 'root',
          exposureDuration: 4.5,
          binning: 1,
          startAltitude: 51,
          rotationStep: 17,
          gain: 120,
          offset: 18,
          startFromCurrent: false,
          isNorth: false,
          manualSlew: true,
        ),
      ];
      final root = InstructionSetNode(
        id: 'root',
        childIds: nodes.map((node) => node.id).toList(growable: false),
      );
      final source = Sequence.create(
        name: 'Codec source',
        rootNodeId: root.id,
        nodes: {root.id: root, for (final node in nodes) node.id: node},
      );

      final snippet = createSnippetFromSelection(
        name: 'Hardware shutdown',
        description: 'Round-trip coverage',
        category: SnippetCategory.custom,
        iconName: 'settings',
        nodeIds: nodes.map((node) => node.id).toList(growable: false),
        sequence: source,
      );

      final container = _newContainer();
      final editor = container.read(currentSequenceProvider.notifier)
        ..createSequence();
      editor.insertSnippet(snippet);
      final inserted = container.read(currentSequenceProvider)!;

      final warm = inserted.nodes.values.whereType<WarmCameraNode>().single;
      expect(warm.ratePerMin, 0.75);
      expect(warm.targetTemp, 12.5);
      expect(warm.comment, 'Avoid dew shock');

      final dither = inserted.nodes.values.whereType<DitherNode>().single;
      expect(dither.settleTimeout, 95);
      expect(dither.raOnly, isTrue);
      expect(dither.pattern, DitherPattern.grid);
      expect(dither.gridSize, 5);

      final rotator = inserted.nodes.values.whereType<RotatorNode>().single;
      expect(rotator.targetAngle, 137.2);
      expect(rotator.relative, isTrue);

      final wait = inserted.nodes.values.whereType<WaitTimeNode>().single;
      expect(wait.waitUntil, waitUntil);
      expect(wait.waitForTwilight, TwilightType.astronomical);

      final script = inserted.nodes.values.whereType<ScriptNode>().single;
      expect(script.scriptPath, '/opt/skotiq/preflight.sh');
      expect(script.arguments, ['--safe', 'M31']);
      expect(script.timeoutSecs, 47);

      final polar = inserted.nodes.values
          .whereType<PolarAlignmentNode>()
          .single;
      expect(polar.exposureDuration, 4.5);
      expect(polar.binning, 1);
      expect(polar.startAltitude, 51);
      expect(polar.rotationStep, 17);
      expect(polar.gain, 120);
      expect(polar.offset, 18);
      expect(polar.startFromCurrent, isFalse);
      expect(polar.isNorth, isFalse);
      expect(polar.manualSlew, isTrue);
    },
  );

  test(
    'custom snippets serialize TargetScheduler and SmartExposure fields',
    () {
      final smart = SmartExposureNode(
        id: 'smart',
        name: 'Ha/OIII Plan',
        parentId: 'scheduler',
        orderIndex: 0,
        plans: const [
          FilterPlan(
            filterName: 'Ha',
            filterIndex: 4,
            count: 12,
            durationSecs: 300,
            gain: 101,
            offset: 20,
            ditherEvery: 2,
          ),
        ],
        rotateFilters: false,
        ditherOnFilterChange: true,
        integrationBudgetSecs: 3600,
        batchSize: 3,
      );
      final scheduler = TargetSchedulerNode(
        id: 'scheduler',
        name: 'Tonight Scheduler',
        childIds: const ['smart'],
        parentId: 'root',
        orderIndex: 0,
        altitudeWeight: 0.4,
        moonDistanceWeight: 0.2,
        transitProximityWeight: 0.15,
        darknessWeight: 0.15,
        airmassWeight: 0.1,
        minScoreToRun: 42,
        recomputeEveryNExposures: 2,
        finishIterationOnSwitch: false,
        swapOnConditionsBelow: 52,
        swapHysteresisSecs: 240,
        brightnessTierPreferences: const BrightnessTierPreferences(
          faintMinScore: 75,
          mediumMinScore: 55,
          brightMinScore: 35,
        ),
        maxConditionsScoreAgeSecs: 420,
      );
      final root = InstructionSetNode(
        id: 'root',
        name: 'Sequence',
        childIds: const ['scheduler'],
      );
      final sequence = Sequence.create(
        name: 'Snippet Source',
        rootNodeId: 'root',
        nodes: {root.id: root, scheduler.id: scheduler, smart.id: smart},
      );

      final snippet = createSnippetFromSelection(
        name: 'Smart Scheduler',
        description: 'Scheduler with smart exposure child',
        category: SnippetCategory.filterSequence,
        iconName: 'layers',
        nodeIds: const ['scheduler'],
        sequence: sequence,
      );

      final schedulerJson = snippet.nodeData.single;
      expect(schedulerJson['nodeType'], 'TargetScheduler');
      expect(schedulerJson['minScoreToRun'], 42);
      expect(schedulerJson['recomputeEveryNExposures'], 2);
      expect(schedulerJson['finishIterationOnSwitch'], isFalse);
      expect(schedulerJson['swapOnConditionsBelow'], 52);
      expect(schedulerJson['swapHysteresisSecs'], 240);
      expect(schedulerJson['maxConditionsScoreAgeSecs'], 420);
      final tierPrefs =
          schedulerJson['brightnessTierPreferences'] as Map<String, dynamic>;
      expect(tierPrefs['faint_min_score'], 75);
      expect(tierPrefs['medium_min_score'], 55);
      expect(tierPrefs['bright_min_score'], 35);

      final smartJson =
          (schedulerJson['children'] as List).single as Map<String, dynamic>;
      expect(smartJson['nodeType'], 'SmartExposure');
      expect(smartJson['rotateFilters'], isFalse);
      expect(smartJson['ditherOnFilterChange'], isTrue);
      expect(smartJson['integrationBudgetSecs'], 3600);
      expect(smartJson['batchSize'], 3);
      final planJson =
          (smartJson['plans'] as List).single as Map<String, dynamic>;
      expect(planJson['filter_name'], 'Ha');
      expect(planJson['duration_secs'], 300);
      expect(planJson['dither_every'], 2);
    },
  );

  test(
    'snippet insertion rebuilds TargetScheduler and SmartExposure nodes',
    () {
      final container = _newContainer();
      final editor = container.read(currentSequenceProvider.notifier)
        ..createSequence();

      final snippet = TemplateSnippet.custom(
        name: 'Imported Smart Scheduler',
        description: 'Uses canonical smart nodes',
        iconName: 'layers',
        nodeData: [
          {
            'id': 'scheduler-old',
            'nodeType': 'target_scheduler',
            'name': 'Scheduler',
            'altitudeWeight': 0.35,
            'moonDistanceWeight': 0.25,
            'transitProximityWeight': 0.2,
            'darknessWeight': 0.1,
            'airmassWeight': 0.1,
            'minScoreToRun': 55,
            'recomputeEveryNExposures': 3,
            'finishIterationOnSwitch': false,
            'swap_on_conditions_below': 48,
            'swap_hysteresis_secs': 210,
            'brightness_tier_preferences': {
              'faint_min_score': 72,
              'medium_min_score': 51,
              'bright_min_score': 29,
            },
            'max_conditions_score_age_secs': 360,
            'children': [
              {
                'id': 'smart-old',
                'nodeType': 'smart_exposure',
                'name': 'Smart Exposure',
                'plans': [
                  {
                    'filter_name': 'OIII',
                    'filter_index': 5,
                    'count': 8,
                    'duration_secs': 240,
                    'gain': 101,
                    'offset': 20,
                    'binning': 'One',
                    'dither_every': 2,
                  },
                ],
                'rotateFilters': false,
                'ditherOnFilterChange': true,
                'integrationBudgetSecs': 1920,
                'batchSize': 2,
              },
            ],
          },
        ],
      );

      editor.insertSnippet(snippet);

      final sequence = container.read(currentSequenceProvider)!;
      final scheduler = sequence.nodes.values
          .whereType<TargetSchedulerNode>()
          .single;
      expect(scheduler.minScoreToRun, 55);
      expect(scheduler.recomputeEveryNExposures, 3);
      expect(scheduler.finishIterationOnSwitch, isFalse);
      expect(scheduler.swapOnConditionsBelow, 48);
      expect(scheduler.swapHysteresisSecs, 210);
      expect(scheduler.maxConditionsScoreAgeSecs, 360);
      expect(scheduler.brightnessTierPreferences.faintMinScore, 72);
      expect(scheduler.brightnessTierPreferences.mediumMinScore, 51);
      expect(scheduler.brightnessTierPreferences.brightMinScore, 29);

      final smart = sequence.nodes.values.whereType<SmartExposureNode>().single;
      expect(smart.parentId, scheduler.id);
      expect(smart.plans, hasLength(1));
      expect(smart.plans.single.filterName, 'OIII');
      expect(smart.plans.single.durationSecs, 240);
      expect(smart.rotateFilters, isFalse);
      expect(smart.ditherOnFilterChange, isTrue);
      expect(smart.integrationBudgetSecs, 1920);
      expect(smart.batchSize, 2);
    },
  );
}
