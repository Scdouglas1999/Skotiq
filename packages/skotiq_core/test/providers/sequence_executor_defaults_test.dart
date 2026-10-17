import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart'
    hide Sequence, SequenceNode;
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/services/scheduler/horizon_profile.dart'
    as sched;
import 'package:skotiq_core/src/providers/sequence/sequence_executor.dart';
import 'package:skotiq_core/src/providers/sequence/sequencer_defaults.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

/// Forces appSettingsProvider into a known state without spinning up
/// the real AsyncNotifier (which reads from SQLite).
class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

ProviderContainer _container({
  required bool autoFocusOnFilterChange,
  required int autoFocusEveryMinutes,
  required bool ditherEnabled,
  required int ditherEveryFrames,
  AppSettingsState? autofocusSettings,
}) {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      appSettingsProvider.overrideWith(
        () => _FakeAppSettingsNotifier(
          autofocusSettings ??
              AppSettingsState(
                autoFocusOnFilterChange: autoFocusOnFilterChange,
                autoFocusEveryMinutes: autoFocusEveryMinutes,
                ditherEnabled: ditherEnabled,
                ditherEveryFrames: ditherEveryFrames,
              ),
        ),
      ),
    ],
  );
  // Why: dispose the container first so any provider that holds a
  // reference to the database can drop it before we close the database
  // itself. Reversing the order triggers "Can't re-open a database
  // after closing it" when async listeners run during dispose.
  addTearDown(() async {
    container.dispose();
    // Let microtasks drain so any pending async listener work finishes
    // before we close the database.
    await Future<void>.delayed(Duration.zero);
    await db.close();
  });
  return container;
}

Sequence _filterThenExposureSequence() {
  // FilterChange -> Exposure -> Exposure (no AF between filter change and
  // exposure). The wire-up should inject an AF synthetic node after the
  // filter change when autoFocusOnFilterChange is true.
  final root = TargetHeaderNode(
    id: 'root',
    name: 'Test target',
    targetName: 'M31',
    raHours: 0,
    decDegrees: 0,
    childIds: const ['filter', 'exp1', 'exp2'],
  );
  final filter = FilterChangeNode(
    id: 'filter',
    name: 'Switch to L',
    filterName: 'L',
    parentId: 'root',
  );
  final exp1 = ExposureNode(
    id: 'exp1',
    parentId: 'root',
    durationSecs: 60,
    count: 5,
  );
  final exp2 = ExposureNode(
    id: 'exp2',
    parentId: 'root',
    durationSecs: 60,
    count: 5,
  );
  return Sequence.create(
    id: 'seq',
    name: 'unit-test',
    rootNodeId: 'root',
    nodes: {'root': root, 'filter': filter, 'exp1': exp1, 'exp2': exp2},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SequenceExecutor._sequenceToJson (§2.1 WIRE-UP #4 / #5)', () {
    test(
      'autofocus settings-default node serializes the real runtime config',
      () async {
        final filterJson = AutofocusSettings.encodeFilterSettingsJson({
          'R': const FilterAutofocusConfig(
            afExposureTime: 8,
            afFilterName: 'L',
            binning: 2,
            gain: 120,
            offset: 15,
          ),
        });
        final container = _container(
          autoFocusOnFilterChange: false,
          autoFocusEveryMinutes: 60,
          ditherEnabled: true,
          ditherEveryFrames: 3,
          autofocusSettings: AppSettingsState(
            afCurveFitting: 'Parabolic',
            afStepSize: 61,
            afExposureTime: 6.5,
            afInitialOffsetSteps: 5,
            afNumberOfAttempts: 4,
            afUseBrightestNStars: 11,
            afOuterCropRatio: 0.8,
            afInnerCropRatio: 0.1,
            afBinning: 3,
            afRSquaredThreshold: 0.88,
            afDisableGuidingDuringAf: true,
            afFocuserSettleTimeMs: 700,
            afExposuresPerPoint: 2,
            afBacklashIn: 140,
            afBacklashOut: 20,
            afAutofocusFilterName: 'L',
            afFilterSettingsJson: filterJson,
          ),
        );
        await container.read(appSettingsProvider.future);
        final root = TargetHeaderNode(
          id: 'root',
          targetName: 'M31',
          raHours: 0,
          decDegrees: 0,
          childIds: const ['af'],
        );
        final af = AutofocusNode(
          id: 'af',
          parentId: 'root',
          useSettingsDefaults: true,
          maxDurationSecs: 333,
        );
        final sequence = Sequence.create(
          id: 'af-sequence',
          name: 'AF',
          rootNodeId: 'root',
          nodes: {'root': root, 'af': af},
        );

        final decoded =
            jsonDecode(
                  container
                      .read(sequenceExecutorProvider)
                      .sequenceToJsonForTest(sequence),
                )
                as Map<String, dynamic>;
        final nodes = (decoded['nodes'] as List).cast<Map<String, dynamic>>();
        final config =
            (nodes.firstWhere((node) => node['id'] == 'af')['node_type']
                as Map<String, dynamic>);

        expect(config['method'], 'Quadratic');
        expect(config['step_size'], 61);
        expect(config['steps_out'], 5);
        expect(config['exposure_duration'], 6.5);
        expect(config['binning'], 'Three');
        expect(config['number_of_attempts'], 4);
        expect(config['exposures_per_point'], 2);
        expect(config['r_squared_threshold'], 0.88);
        expect(config['outer_crop_ratio'], 0.8);
        expect(config['inner_crop_ratio'], 0.1);
        expect(config['use_brightest_n_stars'], 11);
        expect(config['focuser_settle_time_ms'], 700);
        expect(config['backlash_compensation'], 140);
        expect(config['backlash_out_compensation'], 20);
        expect(config['disable_guiding_during_af'], isTrue);
        expect(config['max_duration_secs'], 333);
        expect(config['filter'], 'L');
        expect(
          (config['filter_settings'] as Map)['R'],
          containsPair('gain', 120),
        );
      },
    );

    test('autofocus node overrides only its editable basic fields', () async {
      final container = _container(
        autoFocusOnFilterChange: false,
        autoFocusEveryMinutes: 60,
        ditherEnabled: true,
        ditherEveryFrames: 3,
        autofocusSettings: const AppSettingsState(
          afNumberOfAttempts: 5,
          afBinning: 2,
          afRSquaredThreshold: 0.9,
        ),
      );
      await container.read(appSettingsProvider.future);
      final root = TargetHeaderNode(
        id: 'root',
        targetName: 'M31',
        raHours: 0,
        decDegrees: 0,
        childIds: const ['af'],
      );
      final af = AutofocusNode(
        id: 'af',
        parentId: 'root',
        useSettingsDefaults: false,
        method: AutofocusMethod.hyperbolic,
        stepSize: 91,
        stepsOut: 8,
        exposuresPerPoint: 3,
        exposureDuration: 2.5,
      );
      final sequence = Sequence.create(
        id: 'af-overrides',
        name: 'AF',
        rootNodeId: 'root',
        nodes: {'root': root, 'af': af},
      );

      final decoded =
          jsonDecode(
                container
                    .read(sequenceExecutorProvider)
                    .sequenceToJsonForTest(sequence),
              )
              as Map<String, dynamic>;
      final nodes = (decoded['nodes'] as List).cast<Map<String, dynamic>>();
      final config =
          nodes.firstWhere((node) => node['id'] == 'af')['node_type']
              as Map<String, dynamic>;
      expect(config['method'], 'Hyperbolic');
      expect(config['step_size'], 91);
      expect(config['steps_out'], 8);
      expect(config['exposure_duration'], 2.5);
      expect(config['exposures_per_point'], 3);
      expect(config['number_of_attempts'], 5);
      expect(config['binning'], 'Two');
      expect(config['r_squared_threshold'], 0.9);
    });

    test('injects AF node after filter change when toggle is on', () async {
      final container = _container(
        autoFocusOnFilterChange: true,
        autoFocusEveryMinutes: 60,
        ditherEnabled: true,
        ditherEveryFrames: 3,
      );
      await container.read(appSettingsProvider.future);
      // Warm sequencerDefaultsProvider so its async load completes
      // before we serialise. Without this the notifier hasn't finished
      // reading the (empty) settings DAO before the executor reads it.
      container.read(sequencerDefaultsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final executor = container.read(sequenceExecutorProvider);

      final json = executor.sequenceToJsonForTest(
        _filterThenExposureSequence(),
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final nodes = (decoded['nodes'] as List).cast<Map<String, dynamic>>();
      final rootNode = nodes.firstWhere((n) => n['id'] == 'root');
      final children = (rootNode['children'] as List).cast<String>();

      // children should now be: filter, af-auto-filter, exp1, exp2.
      expect(children.length, 4);
      expect(children[0], 'filter');
      expect(children[1], 'af-auto-filter');
      expect(children[2], 'exp1');
      expect(children[3], 'exp2');

      // The synthetic AF node must be present at the top level.
      final synthetic = nodes.firstWhere((n) => n['id'] == 'af-auto-filter');
      expect(
        (synthetic['node_type'] as Map<String, dynamic>)['type'],
        'Autofocus',
      );
    });

    test('does not inject AF node when toggle is off', () async {
      final container = _container(
        autoFocusOnFilterChange: false,
        autoFocusEveryMinutes: 60,
        ditherEnabled: true,
        ditherEveryFrames: 3,
      );
      await container.read(appSettingsProvider.future);
      // Warm sequencerDefaultsProvider so its async load completes
      // before we serialise. Without this the notifier hasn't finished
      // reading the (empty) settings DAO before the executor reads it.
      container.read(sequencerDefaultsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final executor = container.read(sequenceExecutorProvider);

      final json = executor.sequenceToJsonForTest(
        _filterThenExposureSequence(),
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final nodes = (decoded['nodes'] as List).cast<Map<String, dynamic>>();
      final rootNode = nodes.firstWhere((n) => n['id'] == 'root');
      final children = (rootNode['children'] as List).cast<String>();
      expect(children.length, 3);
      expect(
        nodes.where((n) => (n['id'] as String).startsWith('af-auto-')),
        isEmpty,
      );
    });

    test('metadata carries AF interval and on-filter-change flags', () async {
      final container = _container(
        autoFocusOnFilterChange: true,
        autoFocusEveryMinutes: 45,
        ditherEnabled: true,
        ditherEveryFrames: 3,
      );
      await container.read(appSettingsProvider.future);
      // Warm sequencerDefaultsProvider so its async load completes
      // before we serialise. Without this the notifier hasn't finished
      // reading the (empty) settings DAO before the executor reads it.
      container.read(sequencerDefaultsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final executor = container.read(sequenceExecutorProvider);
      final json = executor.sequenceToJsonForTest(
        _filterThenExposureSequence(),
      );
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final metadata = (decoded['metadata'] as Map<String, dynamic>)
          .cast<String, String>();
      expect(metadata['autofocus_every_minutes'], '45');
      expect(metadata['autofocus_on_filter_change'], 'true');
    });

    test('per-node dither_every wins over app-setting fallback', () async {
      // The user explicitly set ditherEvery=7 on this exposure; the
      // app-setting default of 3 must NOT override it.
      final root = TargetHeaderNode(
        id: 'root',
        name: 'Test',
        targetName: 'M81',
        raHours: 0,
        decDegrees: 0,
        childIds: const ['exp1'],
      );
      final exp1 = ExposureNode(
        id: 'exp1',
        parentId: 'root',
        durationSecs: 60,
        count: 5,
        ditherEvery: 7,
      );
      final sequence = Sequence.create(
        id: 's',
        name: 't',
        rootNodeId: 'root',
        nodes: {'root': root, 'exp1': exp1},
      );

      final container = _container(
        autoFocusOnFilterChange: false,
        autoFocusEveryMinutes: 0,
        ditherEnabled: true,
        ditherEveryFrames: 3,
      );
      await container.read(appSettingsProvider.future);
      // Warm sequencerDefaultsProvider so its async load completes
      // before we serialise. Without this the notifier hasn't finished
      // reading the (empty) settings DAO before the executor reads it.
      container.read(sequencerDefaultsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final executor = container.read(sequenceExecutorProvider);
      final json = executor.sequenceToJsonForTest(sequence);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final nodes = (decoded['nodes'] as List).cast<Map<String, dynamic>>();
      final exposureNode = nodes.firstWhere((n) => n['id'] == 'exp1');
      final cfg = exposureNode['node_type'] as Map<String, dynamic>;
      expect(cfg['dither_every'], 7);
    });

    test(
      'exposure with no ditherEvery falls back to app-setting default',
      () async {
        final root = TargetHeaderNode(
          id: 'root',
          name: 'Test',
          targetName: 'M81',
          raHours: 0,
          decDegrees: 0,
          childIds: const ['exp1'],
        );
        final exp1 = ExposureNode(
          id: 'exp1',
          parentId: 'root',
          durationSecs: 60,
          count: 5,
          ditherEvery: null,
        );
        final sequence = Sequence.create(
          id: 's',
          name: 't',
          rootNodeId: 'root',
          nodes: {'root': root, 'exp1': exp1},
        );

        final container = _container(
          autoFocusOnFilterChange: false,
          autoFocusEveryMinutes: 0,
          ditherEnabled: true,
          ditherEveryFrames: 4,
        );
        await container.read(appSettingsProvider.future);
        // Warm sequencerDefaultsProvider so its async load completes
        // before we serialise. Without this the notifier hasn't finished
        // reading the (empty) settings DAO before the executor reads it.
        container.read(sequencerDefaultsProvider);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final executor = container.read(sequenceExecutorProvider);
        final json = executor.sequenceToJsonForTest(sequence);
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        final nodes = (decoded['nodes'] as List).cast<Map<String, dynamic>>();
        final exposureNode = nodes.firstWhere((n) => n['id'] == 'exp1');
        final cfg = exposureNode['node_type'] as Map<String, dynamic>;
        expect(cfg['dither_every'], 4);
      },
    );

    // Phase B (scheduler-activation): the in-sequence TargetScheduler config
    // emitted to the Rust executor must carry the adaptive-swap threshold and
    // the azimuth horizon mask (samples-only shape) so the already-built Rust
    // swap engine + horizon runnable-gate engage.
    test(
      'TargetScheduler config emits swap threshold + horizon mask',
      () async {
        final scheduler = TargetSchedulerNode(
          id: 'sched',
          name: 'Scheduler',
          childIds: const ['th'],
          swapOnConditionsBelow: 80.0,
          horizonProfile: const sched.HorizonProfile(
            name: 'Site',
            samples: [
              sched.HorizonSample(0.0, 20.0),
              sched.HorizonSample(180.0, 35.0),
            ],
          ),
        );
        final th = TargetHeaderNode(
          id: 'th',
          name: 'M31',
          targetName: 'M31',
          raHours: 0,
          decDegrees: 0,
          parentId: 'sched',
        );
        final sequence = Sequence.create(
          id: 'seq',
          name: 'sched-test',
          rootNodeId: 'sched',
          nodes: {'sched': scheduler, 'th': th},
        );

        final container = _container(
          autoFocusOnFilterChange: false,
          autoFocusEveryMinutes: 0,
          ditherEnabled: false,
          ditherEveryFrames: 0,
        );
        await container.read(appSettingsProvider.future);
        container.read(sequencerDefaultsProvider);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final executor = container.read(sequenceExecutorProvider);

        final json = executor.sequenceToJsonForTest(sequence);
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        final nodes = (decoded['nodes'] as List).cast<Map<String, dynamic>>();
        final schedNode = nodes.firstWhere((n) => n['id'] == 'sched');
        final cfg = schedNode['node_type'] as Map<String, dynamic>;

        expect(cfg['type'], 'TargetScheduler');
        expect(cfg['swap_on_conditions_below'], 80.0);
        // recompute cadence already defaults to 5 (self-driving, ON).
        expect(cfg['recompute_every_n_exposures'], 5);
        // The horizon is serialised as the Rust samples-only shape.
        final horizon = cfg['horizon_profile'] as Map<String, dynamic>;
        final samples = (horizon['samples'] as List)
            .cast<Map<String, dynamic>>();
        expect(samples, hasLength(2));
        expect(samples.first['az'], 0.0);
        expect(samples.first['alt'], 20.0);
      },
    );
  });

  group('SequenceExecutor._sequenceToJson wire contracts', () {
    Future<Map<String, dynamic>> nodeConfig(
      Sequence sequence,
      String nodeId,
    ) async {
      final container = _container(
        autoFocusOnFilterChange: false,
        autoFocusEveryMinutes: 0,
        ditherEnabled: false,
        ditherEveryFrames: 0,
      );
      await container.read(appSettingsProvider.future);
      container.read(sequencerDefaultsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final executor = container.read(sequenceExecutorProvider);
      final json = executor.sequenceToJsonForTest(sequence);
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      final nodes = (decoded['nodes'] as List).cast<Map<String, dynamic>>();
      return nodes.firstWhere((n) => n['id'] == nodeId)['node_type']
          as Map<String, dynamic>;
    }

    Sequence singleNodeSequence(SequenceNode node) => Sequence.create(
      id: 'seq',
      name: 'wire-test',
      rootNodeId: node.id,
      nodes: {node.id: node},
    );

    // The Rust executor compares every epoch field against
    // Utc::now().timestamp() — Unix SECONDS. Milliseconds on the wire made
    // WaitForTime hang forever, start_after unreachable, until-time loops
    // non-terminating, and TimeAfter conditionals never-true.
    final when = DateTime.utc(2026, 7, 20, 21, 30);
    final whenSecs = when.millisecondsSinceEpoch ~/ 1000;

    test('WaitForTime emits wait_until in Unix seconds', () async {
      final cfg = await nodeConfig(
        singleNodeSequence(WaitTimeNode(id: 'wait', waitUntil: when)),
        'wait',
      );
      expect(cfg['type'], 'WaitForTime');
      expect(cfg['wait_until'], whenSecs);
    });

    test('TargetHeader emits start_after/end_before in Unix seconds '
        'plus triggers and integration budget', () async {
      final end = when.add(const Duration(hours: 6));
      final header = TargetHeaderNode(
        id: 'root',
        name: 'M31',
        targetName: 'M31',
        raHours: 0,
        decDegrees: 41,
        startAfter: when,
        endBefore: end,
        startWhen: const TargetTrigger.altitudeAbove(35.0),
        endWhen: const TargetTrigger.altitudeBelow(30.0),
        triggerPollIntervalSecs: 45,
        integrationBudget: const IntegrationBudget(
          totalSecs: 7200,
          perFilter: {'L': FilterBudgetEntry.ratio(4)},
        ),
      );
      final cfg = await nodeConfig(singleNodeSequence(header), 'root');
      expect(cfg['start_after'], whenSecs);
      expect(cfg['end_before'], end.millisecondsSinceEpoch ~/ 1000);
      // The explicit crossings + budget must reach the executor — they were
      // silently dropped before (Rust serde defaults masked the omission).
      expect(cfg['start_when'], {'kind': 'AltitudeAbove', 'value': 35.0});
      expect(cfg['end_when'], {'kind': 'AltitudeBelow', 'value': 30.0});
      expect(cfg['trigger_poll_interval_secs'], 45);
      final budget = cfg['integration_budget'] as Map<String, dynamic>;
      expect(budget['total_secs'], 7200.0);
      expect(budget['stop_on_budget_met'], true);
      expect(budget['per_filter'], {
        'L': {'kind': 'Ratio', 'value': 4.0},
      });
    });

    test('Loop untilTime emits condition_value in Unix seconds', () async {
      final cfg = await nodeConfig(
        singleNodeSequence(
          LoopNode(
            id: 'loop',
            conditionType: LoopConditionType.untilTime,
            repeatUntil: when,
          ),
        ),
        'loop',
      );
      expect(cfg['condition'], 'UntilTime');
      expect(cfg['condition_value'], whenSecs);
    });

    test('Conditional timeAfter emits value in Unix seconds', () async {
      final cfg = await nodeConfig(
        singleNodeSequence(
          ConditionalNode(
            id: 'cond',
            conditionType: ConditionalType.timeAfter,
            thresholdTime: when,
          ),
        ),
        'cond',
      );
      final condition = cfg['condition'] as Map<String, dynamic>;
      expect(condition['type'], 'TimeAfter');
      expect(condition['value'], whenSecs);
    });

    test('Exposure emits frame_type (and defaults to Light)', () async {
      final dark = await nodeConfig(
        singleNodeSequence(ExposureNode(id: 'dark', frameType: FrameType.dark)),
        'dark',
      );
      expect(dark['frame_type'], 'Dark');

      final light = await nodeConfig(
        singleNodeSequence(ExposureNode(id: 'light')),
        'light',
      );
      expect(light['frame_type'], 'Light');
    });
  });
}
