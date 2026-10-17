// Notifier tests for the Darkroom editor's render loop and edit journal.
//
// Every Darkroom native call goes through [DarkroomSeam], so a scripted seam
// exercises the parts that are hard to see from the outside: the debounce that
// turns a slider drag into one render, the single-flight latch that keeps two
// renders out of the engine at once, the generation counter that drops a
// superseded render's pixels, and the cancellation that is an instruction obeyed
// rather than a failure.
//
// The database is real (in-memory): the recipe row is what survives the session,
// so the debounced write is asserted against the row rather than a mock.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_controller.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/mock_database.dart';

/// A Darkroom seam whose every reply the test writes.
class _ScriptedDarkroom implements DarkroomSeam {
  /// Steps the registry's draft carries.
  List<Map<String, dynamic>> draftSteps = [];

  /// The notes the registry recorded while composing that draft — the
  /// operations it decided about and did not carry.
  List<Map<String, dynamic>> draftNotes = [];

  /// Whether `validate` answers ok.
  bool validateOk = true;

  /// The whole-recipe message a refusal carries.
  String validateError = 'a linear operation cannot run after a stretch';

  /// Per-step verdicts the next validate answers with, by index.
  Map<int, String> stepErrors = {};

  /// `opId@opVersion` keys this scripted build does not register.
  ///
  /// Keyed on the operation rather than on a position, because that is what the
  /// engine's registry is keyed on — and because a test that filtered steps out
  /// of the render request would otherwise have to renumber its own fixture.
  /// Both entry points behave the way the engine does: `validate` diagnoses
  /// every step and refuses the recipe as a whole, and `renderPreview` refuses
  /// before it touches a pixel — a step being switched off does not excuse it,
  /// which is exactly why the editor may not send it.
  Set<String> unregisteredOps = {};

  static String _opKey(Map<String, dynamic> step) =>
      '${step['opId']}@${step['opVersion']}';

  /// The first step of [steps] this build does not register, or null.
  int? _firstUnregistered(List<dynamic> steps) {
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i] as Map<String, dynamic>;
      if (unregisteredOps.contains(_opKey(step))) return i;
    }
    return null;
  }

  /// Step indices the next preview reports as skipped, with the reason.
  Map<int, String> skipReasons = {};

  /// Completer the next preview waits on, so a test can hold a render inside
  /// the engine and act while it is there.
  Completer<void>? holdPreview;

  /// When set, the next preview throws this instead of answering.
  Object? previewError;

  /// When set, `validate` throws this instead of answering — the shape a
  /// decode fault or a poisoned engine lock takes at the seam.
  Object? validateThrows;

  final List<String> validateRecipes = [];
  final List<Map<String, dynamic>> previewContexts = [];
  final List<String> previewRecipes = [];
  final List<Map<String, dynamic>> cancelArgs = [];
  final List<Map<String, dynamic>> registryCalls = [];

  int get previewCount => previewRecipes.length;

  @override
  Future<Map<String, dynamic>> validate({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    validateRecipes.add(recipeJson);
    final thrown = validateThrows;
    if (thrown != null) {
      validateThrows = null;
      throw thrown;
    }
    final steps =
        (jsonDecode(recipeJson) as Map<String, dynamic>)['steps'] as List;
    final unknown = _firstUnregistered(steps);
    return {
      'ok': validateOk && unknown == null,
      'error': unknown != null
          ? 'step ${unknown + 1}: no operation registered as '
              '${_opKey(steps[unknown] as Map<String, dynamic>)}'
          : (validateOk ? null : validateError),
      'steps': [
        for (var i = 0; i < steps.length; i++)
          {
            'index': i,
            'opId': (steps[i] as Map<String, dynamic>)['opId'],
            'opVersion': (steps[i] as Map<String, dynamic>)['opVersion'],
            'enabled': (steps[i] as Map<String, dynamic>)['enabled'],
            'registered': !unregisteredOps
                .contains(_opKey(steps[i] as Map<String, dynamic>)),
            'valid': !stepErrors.containsKey(i) &&
                !unregisteredOps
                    .contains(_opKey(steps[i] as Map<String, dynamic>)),
            if (unregisteredOps
                .contains(_opKey(steps[i] as Map<String, dynamic>)))
              'error': 'no operation registered as '
                  '${_opKey(steps[i] as Map<String, dynamic>)}'
            else if (stepErrors.containsKey(i))
              'error': stepErrors[i],
          },
      ],
    };
  }

  @override
  Future<DarkroomRenderedPreview> renderPreview({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    previewRecipes.add(recipeJson);
    previewContexts.add(context);
    final hold = holdPreview;
    if (hold != null) {
      holdPreview = null;
      await hold.future;
    }
    final error = previewError;
    if (error != null) {
      previewError = null;
      throw error;
    }
    final steps =
        (jsonDecode(recipeJson) as Map<String, dynamic>)['steps'] as List;
    final unknown = _firstUnregistered(steps);
    if (unknown != null) {
      throw DarkroomSeamException(
        'renderPreview',
        'step ${unknown + 1}: no operation registered as '
            '${_opKey(steps[unknown] as Map<String, dynamic>)}',
        StateError('unregistered op'),
      );
    }
    return DarkroomRenderedPreview(
      width: 4,
      height: 4,
      isColor: false,
      // Byte 0 carries how many steps THIS render was asked about, so a test
      // can tell one reply's pixels from another's. Without it a superseded
      // render and the one that replaces it answer with identical buffers and
      // "were the stale pixels painted?" has no observable answer.
      rgba: Uint8List(4 * 4 * 4)..[0] = steps.length,
      report: {
        // The engine's own shape (bridge render.rs `description`): an object,
        // never a sentence.
        'encoding': {
          'requested': 'auto',
          'applied': 'screen',
          'sourceDomain': 'linear',
          'clampedSamples': 0,
          'screenTransfer': {
            'blackPoint': 529.75,
            'whitePoint': 531.19,
            'd': 2.57,
          },
          'screenTransferAffectsRecipe': false,
        },
        'level': {
          'level': 1,
          'levelCount': 3,
          'width': 4,
          'height': 4,
          'channels': 1,
          'scaleFromMaster': 0.5,
        },
        'report': {
          'steps': [
            for (var i = 0; i < steps.length; i++)
              {
                'index': i,
                'opId': (steps[i] as Map<String, dynamic>)['opId'],
                'opVersion': 1,
                'outcome':
                    ((steps[i] as Map<String, dynamic>)['enabled'] as bool) ==
                            false
                        ? 'disabled'
                        : (skipReasons.containsKey(i) ? 'skipped' : 'applied'),
                if (skipReasons.containsKey(i)) 'reason': skipReasons[i],
              },
          ],
        },
      },
    );
  }

  @override
  Future<Map<String, dynamic>> renderExport({
    required String recipeJson,
    required Map<String, dynamic> args,
  }) async {
    throw StateError('the editor does not export in these tests');
  }

  @override
  Future<Map<String, dynamic>> registry(Map<String, dynamic> args) async {
    registryCalls.add(args);
    final reply = <String, dynamic>{
      'schemaVersion': 1,
      'ops': [
        {
          'id': 'background_extract',
          'version': 1,
          'stage': 'linear',
          'summary': 'Fits and subtracts a smooth background model.',
          'params': [
            {
              'name': 'sampleSpacing',
              'kind': 'number',
              'required': false,
              'min': 8.0,
              'max': 1024.0,
              'default': 64.0,
              'example': 64.0,
              'independent': true,
              'summary': 'Spacing between background sample boxes.',
            },
          ],
        },
        {
          'id': 'color_calibrate',
          'version': 1,
          'stage': 'linear',
          'summary': 'Fits a B−V colour-versus-flux regression.',
          'params': const <dynamic>[],
        },
        {
          'id': 'stretch',
          'version': 1,
          'stage': 'stretched',
          'summary': 'Generalized hyperbolic stretch.',
          'params': [
            {
              'name': 'blackPoint',
              'kind': 'number',
              'required': true,
              'min': -1e12,
              'max': 1e12,
              'example': 0.0,
              'independent': false,
              'summary': 'Input level mapped to black.',
            },
          ],
        },
      ],
    };
    if (args['masterPath'] != null) {
      reply['draft'] = {
        'recipe': {
          'id': 'draft',
          'schemaVersion': 1,
          'baseMasterRef': args['masterPath'],
          'createdBy': 'autopilot',
          'steps': draftSteps,
        },
        'notes': draftNotes,
        'autoParams': const <String, dynamic>{},
      };
    }
    return reply;
  }

  @override
  Future<Map<String, dynamic>> cancel(Map<String, dynamic> args) async {
    cancelArgs.add(args);
    return {
      'renderId': args['renderId'],
      'op': args['op'],
      'running': true,
      'cancelRequested': true,
    };
  }
}

/// A photometry resolver bound to an empty catalogue, so no test reaches the
/// on-disk star catalogue.
DawnPhotometryResolver _emptyPhotometry() {
  return DawnPhotometryResolver(
    coneSearch: (center, radiusDegrees, {maxMagnitude}) async => const [],
  );
}

const String _masterPath = '/tmp/skotiq-test/m31_L.fits';

Map<String, dynamic> _step(
  String opId, {
  bool enabled = true,
  int opVersion = 1,
  Map<String, dynamic> params = const {},
}) {
  return {
    'opId': opId,
    'opVersion': opVersion,
    'params': params,
    'enabled': enabled,
  };
}

/// The `(opId, opVersion)` pairs one render request carried, in order.
List<String> _askedOps(String recipeJson) {
  final steps = (jsonDecode(recipeJson) as Map<String, dynamic>)['steps']
      as List<dynamic>;
  return [
    for (final step in steps)
      '${(step as Map<String, dynamic>)['opId']}@${step['opVersion']}',
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ScriptedDarkroom darkroom;
  late ProviderContainer container;
  late SkotiqDatabase db;
  late RecipesDao recipes;

  setUp(() {
    darkroom = _ScriptedDarkroom();
    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        darkroomSeamProvider.overrideWithValue(darkroom),
        dawnPhotometryResolverProvider.overrideWithValue(_emptyPhotometry()),
      ],
    );
    addTearDown(container.dispose);
    db = container.read(databaseProvider);
    recipes = container.read(recipesDaoProvider);
  });

  Future<int> seedRecipe({
    List<Map<String, dynamic>> steps = const [],
    String name = 'Draft',
  }) {
    return recipes.create(
      masterId: null,
      baseMasterPath: _masterPath,
      name: name,
      stepsJson: jsonEncode(steps),
      createdBy: RecipeAuthor.autopilot,
    );
  }

  /// Hold one scope's controller open for the length of the test.
  ///
  /// The provider is autoDispose — a controller that outlives the screen that
  /// made it is what served a stale recipe row — so a bare `container.read`
  /// builds a controller and tears it down again before its load settles. This
  /// subscription is what a mounted screen's `ref.watch` does; the container's
  /// own teardown closes it.
  void open(DarkroomScope scope) {
    container.listen<DarkroomState>(
      darkroomControllerProvider(scope),
      (_, __) {},
      fireImmediately: true,
    );
  }

  /// Let the edit debounce elapse and the validate/render pair that follows it
  /// run to completion.
  Future<void> pumpDebounces() async {
    await Future<void>.delayed(
      kDarkroomSaveDebounce + const Duration(milliseconds: 80),
    );
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Read the state after the load, the catalogue fetch and the first render
  /// have all settled.
  Future<DarkroomState> settle(DarkroomScope scope) async {
    open(scope);
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return container.read(darkroomControllerProvider(scope));
  }

  test('a link that names nothing loads an explanation, not a crash', () async {
    final state = await settle(const DarkroomScope.empty());
    expect(state.loading, isFalse);
    expect(state.loadError, contains('named neither a recipe nor a master'));
    expect(state.hasRecipe, isFalse);
  });

  test('a recipe id with no row says so', () async {
    final state = await settle(const DarkroomScope.recipe(4242));
    expect(state.loadError, contains('Recipe 4242 no longer has a row'));
    // `recipes.master_id` is ON DELETE SET NULL, so a deleted master cannot
    // take a recipe row with it. The sentence used to speculate that it might
    // have, which read as "the master is gone" over a master still on disk.
    expect(state.loadError, contains('still in the library'));
    expect(state.loadError, isNot(contains('deleted along with the master')));
  });

  test('loading a recipe renders it once and reports every step', () async {
    final id = await seedRecipe(
      steps: [_step('background_extract'), _step('stretch')],
    );
    final state = await settle(DarkroomScope.recipe(id));

    expect(state.loadError, isNull);
    expect(state.steps, hasLength(2));
    expect(state.baseMasterPath, _masterPath);
    expect(darkroom.previewCount, 1);
    expect(state.preview, isNotNull);
    expect(state.preview!.scaleFromMaster, 0.5);
    expect(state.reports.map((r) => r.outcome), [
      DarkroomStepOutcome.applied,
      DarkroomStepOutcome.applied,
    ]);
    // The render is asked for under a cancellable id and at a preview level.
    expect(darkroom.previewContexts.single['renderId'], isA<String>());
    expect(
      darkroom.previewContexts.single['maxDimension'],
      kDarkroomPreviewMaxDimension,
    );
  });

  test('a skipped step keeps its reason on the state', () async {
    darkroom.skipReasons = {
      0: 'no catalogue star was resolved for this field, so the colour fit has '
          'nothing to regress against',
    };
    final id = await seedRecipe(steps: [_step('color_calibrate')]);
    final state = await settle(DarkroomScope.recipe(id));

    final report = state.reportFor(0);
    expect(report, isNotNull);
    expect(report!.outcome, DarkroomStepOutcome.skipped);
    expect(report.reason, contains('nothing to regress against'));
  });

  test('a toggle renders once after the debounce, not once per edit', () async {
    final id = await seedRecipe(
      steps: [_step('background_extract'), _step('stretch')],
    );
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final baseline = darkroom.previewCount;

    final controller =
        container.read(darkroomControllerProvider(scope).notifier)
          ..toggleStep(0)
          ..toggleStep(1)
          ..toggleStep(0);
    expect(controller.state.steps[0].enabled, isTrue);

    // Nothing has rendered yet: the debounce is still open.
    await Future<void>.delayed(Duration.zero);
    expect(darkroom.previewCount, baseline);

    await Future<void>.delayed(
      kDarkroomRenderDebounce + const Duration(milliseconds: 60),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(darkroom.previewCount, baseline + 1);
    expect(controller.state.steps[1].enabled, isFalse);
    expect(
        controller.state.reportFor(1)!.outcome, DarkroomStepOutcome.disabled);
  });

  test('a superseded render is cancelled by its own id and dropped', () async {
    final id = await seedRecipe(steps: [_step('background_extract')]);
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );

    // Hold the next render inside the engine, then edit again underneath it.
    final held = Completer<void>();
    darkroom.holdPreview = held;
    controller.toggleStep(0);
    await Future<void>.delayed(
      kDarkroomRenderDebounce + const Duration(milliseconds: 60),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.rendering, isTrue);
    final inFlightRenders = darkroom.previewCount;

    controller.toggleStep(0);
    await Future<void>.delayed(
      kDarkroomRenderDebounce + const Duration(milliseconds: 60),
    );
    // The superseded render was asked to stop by its own id; no second render
    // entered the engine beside it.
    expect(darkroom.cancelArgs, isNotEmpty);
    expect(darkroom.cancelArgs.last['op'], 'cancel');
    expect(darkroom.cancelArgs.last['renderId'], isA<String>());
    expect(darkroom.previewCount, inFlightRenders);

    held.complete();
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    // Exactly one further render ran, and it carried the newest step list.
    expect(darkroom.previewCount, inFlightRenders + 1);
    expect(controller.state.rendering, isFalse);
    expect(controller.state.steps[0].enabled, isTrue);
  });

  test('a cancelled render is an instruction obeyed, not a failure', () async {
    final id = await seedRecipe(steps: [_step('background_extract')]);
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );
    final firstPixels = controller.state.preview;

    final held = Completer<void>();
    darkroom.holdPreview = held;
    darkroom.previewError = const DarkroomCancelledOutcome(
      id: 'darkroom-editor',
      phase: 'render',
      payload: {'kind': 'cancelled'},
    );
    controller.toggleStep(0);
    await Future<void>.delayed(
      kDarkroomRenderDebounce + const Duration(milliseconds: 60),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.rendering, isTrue);

    await controller.cancelRender();
    expect(controller.state.cancelRequested, isTrue);
    expect(darkroom.cancelArgs.last['op'], 'cancel');

    held.complete();
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.state.rendering, isFalse);
    expect(controller.state.cancelRequested, isFalse);
    expect(controller.state.renderError, isNull);
    expect(controller.state.cancelledPhase, 'render');
    // The previous picture is still on screen.
    expect(identical(controller.state.preview, firstPixels), isTrue);
  });

  test('a render failure is surfaced with the engine\'s own words', () async {
    final id = await seedRecipe(steps: [_step('background_extract')]);
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );

    darkroom.previewError = const DarkroomSeamException(
      'renderPreview',
      'the master could not be read: no such file',
      'boom',
    );
    controller.toggleStep(0);
    await Future<void>.delayed(
      kDarkroomRenderDebounce + const Duration(milliseconds: 60),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.state.rendering, isFalse);
    expect(controller.state.renderError, contains('no such file'));
  });

  test('an illegal reorder is refused before it is applied', () async {
    final id = await seedRecipe(
      steps: [_step('background_extract'), _step('stretch')],
    );
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );
    final renders = darkroom.previewCount;

    darkroom.validateOk = false;
    final accepted = await controller.reorderStep(1, 0);

    expect(accepted, isFalse);
    expect(controller.state.steps.map((s) => s.opId), [
      'background_extract',
      'stretch',
    ]);
    expect(
      controller.state.reorderRefusal,
      contains('linear operation cannot run after a stretch'),
    );
    // A refused order never reaches the engine's renderer.
    await Future<void>.delayed(
      kDarkroomRenderDebounce + const Duration(milliseconds: 60),
    );
    expect(darkroom.previewCount, renders);
  });

  test('a legal reorder commits and re-renders', () async {
    final id = await seedRecipe(
      steps: [_step('background_extract'), _step('color_calibrate')],
    );
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );
    final renders = darkroom.previewCount;

    final accepted = await controller.reorderStep(1, 0);
    expect(accepted, isTrue);
    expect(controller.state.steps.map((s) => s.opId), [
      'color_calibrate',
      'background_extract',
    ]);

    await Future<void>.delayed(
      kDarkroomRenderDebounce + const Duration(milliseconds: 60),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(darkroom.previewCount, renders + 1);
  });

  test('reset to linear turns every step off and destroys nothing', () async {
    final id = await seedRecipe(
      steps: [
        _step('background_extract', params: {'sampleSpacing': 32.0}),
        _step('stretch'),
      ],
    );
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );

    controller.resetToLinear();
    expect(controller.state.isLinear, isTrue);
    expect(controller.state.steps, hasLength(2));
    expect(
      controller.state.steps.first.params['sampleSpacing'],
      32.0,
    );

    controller.undo();
    expect(controller.state.steps.every((s) => s.enabled), isTrue);
    controller.redo();
    expect(controller.state.isLinear, isTrue);
  });

  test('consecutive drags of one slider are a single undo step', () async {
    final id = await seedRecipe(steps: [_step('background_extract')]);
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );

    for (final value in [70.0, 80.0, 90.0, 120.0]) {
      controller.setParam(0, 'sampleSpacing', value);
    }
    expect(controller.state.steps.first.params['sampleSpacing'], 120.0);

    controller.undo();
    // One undo goes back past the whole drag, not one frame of it.
    expect(
      controller.state.steps.first.params.containsKey('sampleSpacing'),
      isFalse,
    );
    expect(controller.state.canUndo, isFalse);
  });

  test('an edit reaches the recipe row after the save debounce', () async {
    final id = await seedRecipe(steps: [_step('background_extract')]);
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );

    controller.toggleStep(0);
    expect(controller.state.savePending, isTrue);

    await Future<void>.delayed(
      kDarkroomSaveDebounce + const Duration(milliseconds: 80),
    );
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.state.savePending, isFalse);

    final stored = await recipes.getById(id);
    final steps = jsonDecode(stored!.stepsJson) as List;
    expect((steps.single as Map<String, dynamic>)['enabled'], isFalse);
  });

  test('a master with no recipe offers both starting points', () async {
    final masters = IntegratedMastersDao(db);
    final targetId = await TargetsDao(db).createTarget(
      const TargetsCompanion(
        name: Value('M31'),
        ra: Value(0.712),
        dec: Value(41.27),
      ),
    );
    final masterId = await masters.insertMaster(
      targetId: targetId,
      name: 'M31 L',
      masterFitsPath: _masterPath,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      channels: 1,
      width: 4096,
      height: 3096,
      frameCount: 41,
      totalIntegrationSeconds: 12300,
      settingsJson: '{}',
      statsJson: '{}',
    );

    final scope = DarkroomScope.master(masterId);
    final state = await settle(scope);
    expect(state.offer, isNotNull);
    expect(state.offer!.masterName, 'M31 L');
    expect(state.hasRecipe, isFalse);

    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );
    darkroom.draftSteps = [_step('background_extract'), _step('stretch')];
    await controller.draftForMe();
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(controller.state.offer, isNull);
    expect(controller.state.hasRecipe, isTrue);
    expect(controller.state.author, RecipeAuthor.user);
    expect(controller.state.steps.map((s) => s.opId), [
      'background_extract',
      'stretch',
    ]);
    final stored = await recipes.listForMaster(_masterPath);
    expect(stored, hasLength(1));
    expect(stored.single.masterId, masterId);
    expect(stored.single.targetId, targetId);
    expect(
      stored.single.name,
      'M31 L draft',
      reason: 'the recipe is named after the master it is drafted over, the '
          'way the dawn autopilot names its own — a bare "Draft" read back as '
          '"Rendered draft of Draft" in the viewport semantics',
    );
  });

  /// Insert one finalized master and return its row id.
  Future<int> seedMaster({
    required int width,
    required int height,
    String name = 'Master · B',
  }) {
    return IntegratedMastersDao(db).insertMaster(
      targetId: null,
      name: name,
      masterFitsPath: _masterPath,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      channels: 1,
      width: width,
      height: height,
      frameCount: 12,
      totalIntegrationSeconds: 3600,
      settingsJson: '{}',
      statsJson: '{}',
    );
  }

  test('a drafted crop over the whole master is left out, with the reason',
      () async {
    final masterId = await seedMaster(width: 1920, height: 1080);
    final scope = DarkroomScope.master(masterId);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );

    // What the registry returns for a stack whose frames all cover the same
    // pixels: the largest fully-covered rectangle IS the frame.
    darkroom.draftSteps = [
      _step('crop', params: {'x': 0, 'y': 0, 'width': 1920, 'height': 1080}),
      _step('stretch'),
    ];
    await controller.draftForMe();
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(
      controller.state.steps.map((s) => s.opId),
      ['stretch'],
      reason: 'a crop that trims nothing would list a step that changes no '
          'pixel',
    );
    final note = controller.state.draftNotes.singleWhere(
      (n) => n.opId == 'crop',
    );
    expect(note.outcome, 'omitted');
    expect(note.reason, contains('whole 1920×1080 frame'));
    final stored = await recipes.listForMaster(_masterPath);
    expect(
      jsonDecode(stored.single.stepsJson),
      hasLength(1),
      reason: 'the row carries what the editor shows',
    );
  });

  test('a drafted crop that trims an edge is carried', () async {
    final masterId = await seedMaster(width: 1920, height: 1080);
    final scope = DarkroomScope.master(masterId);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );

    darkroom.draftSteps = [
      _step('crop', params: {'x': 8, 'y': 6, 'width': 1900, 'height': 1060}),
      _step('stretch'),
    ];
    await controller.draftForMe();
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(controller.state.steps.map((s) => s.opId), ['crop', 'stretch']);
    expect(
      controller.state.steps.first.params,
      {'x': 8, 'y': 6, 'width': 1900, 'height': 1060},
    );
    expect(
      controller.state.draftNotes.singleWhere((n) => n.opId == 'crop').outcome,
      'included',
    );
  });

  test('start from linear creates an empty user recipe', () async {
    final masters = IntegratedMastersDao(db);
    final masterId = await masters.insertMaster(
      targetId: null,
      name: 'NGC 7000 Ha',
      masterFitsPath: _masterPath,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      channels: 1,
      width: 1024,
      height: 1024,
      frameCount: 12,
      totalIntegrationSeconds: 3600,
      settingsJson: '{}',
      statsJson: '{}',
    );
    final scope = DarkroomScope.master(masterId);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );

    await controller.startFromLinear();
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.state.hasRecipe, isTrue);
    expect(controller.state.steps, isEmpty);
    expect(controller.state.recipeName, 'Linear');
  });

  test('the operation catalogue drives the parameter specs', () async {
    final id = await seedRecipe(steps: [_step('background_extract')]);
    final state = await settle(DarkroomScope.recipe(id));

    final catalog = state.catalog;
    expect(catalog, isNotNull);
    final spec = catalog!.specFor(state.steps.single);
    expect(spec, isNotNull);
    expect(spec!.stage, DarkroomOpStage.linear);
    final param = spec.param('sampleSpacing');
    expect(param, isNotNull);
    expect(param!.min, 8.0);
    expect(param.max, 1024.0);
    expect(param.defaultValue, 64.0);
    expect(param.isSliderRanged, isTrue);

    // A ±1e12 range is not something a slider can resolve, so it takes a field.
    final stretch = catalog.ops.firstWhere((op) => op.id == 'stretch');
    expect(stretch.stage, DarkroomOpStage.stretched);
    expect(stretch.param('blackPoint')!.isSliderRanged, isFalse);
    expect(stretch.param('blackPoint')!.independent, isFalse);
  });

  test('the render report\'s encoding object is read, not stringified',
      () async {
    final id = await seedRecipe(steps: [_step('background_extract')]);
    final state = await settle(DarkroomScope.recipe(id));

    final encoding = state.preview!.encoding;
    expect(encoding.applied, 'screen');
    expect(encoding.sourceDomain, 'linear');
    expect(encoding.screenTransfer, isNotNull);
    expect(encoding.screenTransfer!['blackPoint'], 529.75);
    // Both halves are named, so the strip never blames the engine for an
    // omission it did not make.
    expect(encoding.sentence, contains('screen transfer'));
    expect(encoding.sentence, contains('still-linear pixels'));
    expect(encoding.sentence, isNot(contains('did not name')));
  });

  test('an encoding block the reply omits is reported as unstated', () {
    final encoding = decodeDarkroomEncoding(const <String, dynamic>{});
    expect(encoding.applied, isNull);
    expect(encoding.sourceDomain, isNull);
    expect(encoding.screenTransfer, isNull);
    expect(
      encoding.sentence,
      'the engine did not name the display transfer it applied',
    );
  });

  test('an encoding block naming only the transfer says so for the domain', () {
    final encoding = decodeDarkroomEncoding(const <String, dynamic>{
      'encoding': <String, dynamic>{'applied': 'unit'},
    });
    expect(encoding.applied, 'unit');
    expect(encoding.sourceDomain, isNull);
    expect(encoding.sentence, contains('own samples'));
    expect(encoding.sentence, contains('domain the engine did not name'));
  });

  test('a reorder whose check throws is refused with the failure named',
      () async {
    final id = await seedRecipe(
      steps: [_step('background_extract'), _step('stretch')],
    );
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );

    darkroom.validateThrows = StateError('the registry lock was poisoned');
    final accepted = await controller.reorderStep(1, 0);

    // The caller is a drag gesture that cannot await this, so a throw here
    // would have been an unobserved async error and a silently snapped-back
    // card. It is a stated refusal instead.
    expect(accepted, isFalse);
    expect(
      controller.state.reorderRefusal,
      contains('could not be checked with the engine'),
    );
    expect(
      controller.state.reorderRefusal,
      contains('the registry lock was poisoned'),
    );
    expect(controller.state.steps.map((s) => s.opId), [
      'background_extract',
      'stretch',
    ]);
  });

  test('a stored step list that is not a step list is reported', () async {
    final id = await recipes.create(
      baseMasterPath: _masterPath,
      name: 'Corrupt',
      stepsJson: '{"not":"a list"}',
      createdBy: RecipeAuthor.user,
    );
    final state = await settle(DarkroomScope.recipe(id));
    expect(state.loadError, contains('JSON array of steps'));
    expect(state.hasRecipe, isFalse);
    // The operator is told what the row holds in the vocabulary of the file
    // being read, not in Dart's private class names.
    expect(state.loadError, contains('a JSON object'));
    expect(state.loadError, isNot(contains('_Map')));
    expect(state.loadError, isNot(contains('dynamic')));
  });

  test('a step this build cannot run blocks the render while it is on',
      () async {
    darkroom.unregisteredOps = {'stretch@99'};
    final id = await seedRecipe(
      steps: [
        _step('background_extract'),
        _step('stretch', opVersion: 99),
      ],
    );
    final state = await settle(DarkroomScope.recipe(id));

    expect(
        state.renderError, contains('no operation registered as stretch@99'));
    expect(state.blockingRecipeError,
        contains('no operation registered as stretch@99'));
    expect(state.issueFor(1)!.registered, isFalse);
    // The render was asked about it, because it is switched on: leaving an
    // enabled step out would render a recipe the operator did not write.
    expect(_askedOps(darkroom.previewRecipes.last), [
      'background_extract@1',
      'stretch@99',
    ]);
  });

  test('switching that step off renders the rest and states the omission',
      () async {
    darkroom.unregisteredOps = {'stretch@99'};
    final id = await seedRecipe(
      steps: [
        _step('background_extract'),
        _step('stretch', opVersion: 99),
      ],
    );
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );

    controller.toggleStep(1);
    await pumpDebounces();

    // The render replays enabled steps only, so a step that is off cannot be
    // what stops it — and now does not.
    expect(_askedOps(darkroom.previewRecipes.last), ['background_extract@1']);
    expect(controller.state.renderError, isNull);
    expect(controller.state.preview, isNotNull);
    expect(controller.state.blockingRecipeError, isNull);
    // The step still says, on its own card, what this build cannot do with it.
    expect(controller.state.issueFor(1)!.registered, isFalse);
    expect(controller.state.isOmittedFromRender(1), isTrue);
    expect(controller.state.isOmittedFromRender(0), isFalse);
  });

  test('a refusal over a filtered request says what its step number counts',
      () async {
    darkroom.unregisteredOps = {'denoise@99', 'chrono_warp@1'};
    final id = await seedRecipe(
      steps: [
        _step('background_extract'),
        _step('denoise', opVersion: 99, enabled: false),
        _step('chrono_warp'),
        _step('stretch'),
      ],
    );
    final state = await settle(DarkroomScope.recipe(id));

    // The disabled step is left out, so the engine calls chrono_warp step 2 of
    // the three it was given while the operator counts it third in the panel.
    // Both count from 1; they count different lists, which is what the
    // appended sentence is for.
    expect(state.renderError, contains('chrono_warp@1'));
    expect(state.renderError, contains('step 2'));
    expect(
      state.renderError,
      contains('asked without 1 switched-off step this build cannot run'),
    );
  });

  test('a disabled step this build DOES register stays in the render',
      () async {
    final id = await seedRecipe(
      steps: [_step('background_extract'), _step('stretch', enabled: false)],
    );
    final state = await settle(DarkroomScope.recipe(id));

    // The engine is the one that reports a step as disabled, and it can only do
    // that for a step it was given.
    expect(_askedOps(darkroom.previewRecipes.last), [
      'background_extract@1',
      'stretch@1',
    ]);
    expect(state.isOmittedFromRender(1), isFalse);
    expect(state.reportFor(1)!.outcome, DarkroomStepOutcome.disabled);
  });

  test('removing a step takes it out of the recipe, and undo puts it back',
      () async {
    darkroom.unregisteredOps = {'stretch@99'};
    final id = await seedRecipe(
      steps: [
        _step('background_extract'),
        _step('stretch', opVersion: 99, params: {'blackPoint': 12.0}),
      ],
    );
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );

    controller.removeStep(1);
    await pumpDebounces();

    expect(controller.state.steps.map((s) => s.opId), ['background_extract']);
    expect(controller.state.renderError, isNull);
    expect(controller.state.canUndo, isTrue);
    final stored = await recipes.getById(id);
    expect(jsonDecode(stored!.stepsJson), hasLength(1));

    controller.undo();
    await pumpDebounces();

    expect(controller.state.steps.map((s) => s.opId), [
      'background_extract',
      'stretch',
    ]);
    // The parameters come back with it — an undo restores the step, not a
    // freshly defaulted one.
    expect(controller.state.steps[1].params['blackPoint'], 12.0);
  });

  test('an outcome follows its own step when the stack shifts under it',
      () async {
    final id = await seedRecipe(
      steps: [_step('background_extract'), _step('stretch')],
    );
    final scope = DarkroomScope.recipe(id);
    final first = await settle(scope);
    expect(first.reportFor(0)!.opId, 'background_extract');
    expect(first.reportFor(1)!.opId, 'stretch');

    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );
    // Hold the next render inside the engine, so the stack is read in the gap
    // between the edit and the outcomes that will describe it — the state the
    // operator sees for the length of the debounce.
    darkroom.holdPreview = Completer<void>();
    controller.removeStep(0);
    await pumpDebounces();

    expect(controller.state.steps.map((s) => s.opId), ['stretch']);
    // Index 0 is now the stretch. The line the engine wrote for index 0 was
    // about the background extraction, which is no longer in the recipe at all;
    // reading it onto this card is how a step wears an outcome nothing produced
    // for it.
    expect(controller.state.reportFor(0)!.opId, 'stretch');
  });

  test('a reload onto a changed row badges nothing from the render before it',
      () async {
    final id = await seedRecipe(
      steps: [_step('background_extract'), _step('stretch')],
    );
    final scope = DarkroomScope.recipe(id);
    final first = await settle(scope);
    expect(first.reportFor(0)!.outcome, DarkroomStepOutcome.applied);

    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );
    // The row changes behind the editor's back and the operator presses Reload;
    // the render then refuses on the step this build cannot run.
    darkroom.unregisteredOps = {'denoise@99'};
    await recipes.updateSteps(
      id,
      jsonEncode([
        _step('background_extract'),
        _step('denoise', opVersion: 99),
        _step('stretch'),
      ]),
    );
    await controller.refresh();
    await pumpDebounces();

    expect(controller.state.renderError,
        contains('no operation registered as denoise@99'));
    expect(controller.state.reports, isEmpty);
    for (var i = 0; i < controller.state.steps.length; i++) {
      expect(controller.state.reportFor(i), isNull);
    }
  });

  test('a render that does not finish leaves no outcomes behind', () async {
    final id = await seedRecipe(
      steps: [_step('background_extract'), _step('stretch')],
    );
    final scope = DarkroomScope.recipe(id);
    final first = await settle(scope);
    expect(first.reportFor(0)!.outcome, DarkroomStepOutcome.applied);

    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );
    darkroom.previewError = const DarkroomSeamException(
      'renderPreview',
      "cannot read '/tmp/skotiq-test/m31_L.fits': No such file or directory",
      'io',
    );
    await controller.refreshRender();
    await pumpDebounces();

    expect(controller.state.renderError, contains('No such file or directory'));
    // Nothing was applied by the render that just failed, so no step may say it
    // was.
    expect(controller.state.reports, isEmpty);
    expect(controller.state.reportFor(0), isNull);
    expect(controller.state.reportFor(1), isNull);
  });

  test('re-opening a scope re-reads the row rather than serving what it held',
      () async {
    final id = await seedRecipe(
      steps: [_step('background_extract'), _step('stretch')],
    );
    final scope = DarkroomScope.recipe(id);
    final subscription = container.listen<DarkroomState>(
      darkroomControllerProvider(scope),
      (_, __) {},
      fireImmediately: true,
    );
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(
        container.read(darkroomControllerProvider(scope)).steps, hasLength(2));

    // The screen goes away, and the row changes behind the editor's back — the
    // second entry point over the same master, another device, a repair.
    subscription.close();
    await Future<void>.delayed(Duration.zero);
    await recipes.updateSteps(
      id,
      jsonEncode(
          [_step('background_extract'), _step('denoise'), _step('stretch')]),
    );

    final reopened = await settle(scope);
    expect(reopened.steps.map((s) => s.opId), [
      'background_extract',
      'denoise',
      'stretch',
    ]);
  });

  test(
      'a scope whose row is gone re-opens as the sentinel, not as the row it '
      'last held', () async {
    final id = await seedRecipe(steps: [_step('background_extract')]);
    final scope = DarkroomScope.recipe(id);
    final subscription = container.listen<DarkroomState>(
      darkroomControllerProvider(scope),
      (_, __) {},
      fireImmediately: true,
    );
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(darkroomControllerProvider(scope)).hasRecipe, isTrue);

    subscription.close();
    await Future<void>.delayed(Duration.zero);
    await recipes.deleteRecipe(id);

    final reopened = await settle(scope);
    expect(reopened.hasRecipe, isFalse);
    expect(reopened.loadError, contains('Recipe $id no longer has a row'));
  });

  test(
      'a render the operator has edited past never reaches the viewport, even '
      'inside the debounce', () async {
    final id = await seedRecipe(
      steps: [_step('crop'), _step('background_extract'), _step('stretch')],
    );
    final scope = DarkroomScope.recipe(id);
    final first = await settle(scope);
    expect(first.preview!.rgba[0], 3, reason: 'the first render is the stack');

    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );

    // One edit, and the render it schedules is held inside the engine.
    final held = Completer<void>();
    darkroom.holdPreview = held;
    controller.removeStep(0);
    await pumpDebounces();
    expect(darkroom.previewCount, 2, reason: 'the two-step render is running');

    // A second edit while that render is still in the engine. The reply lands
    // BEFORE the new debounce fires — the window in which the generation used
    // not to have moved yet, so the superseded pixels were painted.
    controller.removeStep(0);
    held.complete();
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final duringDebounce = container.read(darkroomControllerProvider(scope));
    expect(duringDebounce.steps, hasLength(1));
    expect(
      duringDebounce.preview!.rgba[0],
      3,
      reason: 'the two-step reply describes a recipe that is already gone, so '
          'the last picture the operator can trust stays up',
    );

    // The stack the operator ended on is what finally renders.
    await pumpDebounces();
    final settled = container.read(darkroomControllerProvider(scope));
    expect(settled.preview!.rgba[0], 1);
  });

  test('a refused reorder numbers its steps over the order it was refused for',
      () async {
    final id = await seedRecipe(
      steps: [
        _step('crop'),
        _step('background_extract'),
        _step('denoise'),
        _step('stretch'),
      ],
    );
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );

    // The engine's own sentence, numbering the order it was HANDED from 1:
    // moving stretch above denoise makes [crop, background_extract, stretch,
    // denoise], in which denoise is step 4 and stretch step 3.
    darkroom.validateOk = false;
    darkroom.validateError =
        'step 4 (denoise@1) is a linear-stage operation but step 3 (stretch) '
        'already left the linear stage';

    final moved = await controller.reorderStep(3, 2);
    expect(moved, isFalse);
    expect(controller.state.steps.map((s) => s.opId), [
      'crop',
      'background_extract',
      'denoise',
      'stretch',
    ]);

    final refusal = controller.state.reorderRefusal!;
    // Counted from 1 in the order the move was ASKING for: there stretch is
    // 3rd and denoise 4th, which is the arrangement the rule refuses. Re-
    // pointing the numbers at the cards on screen instead kept both names and
    // inverted the relation — "step 3 (denoise) ... but step 4 (stretch)"
    // describes the order the operator is looking at, and that one is LEGAL.
    expect(refusal, contains('step 4 (denoise@1)'));
    expect(refusal, contains('step 3 (stretch)'));
    expect(refusal, isNot(contains('step 4 (stretch)')));
    expect(
      refusal,
      contains('count the order the move would have produced, from 1'),
    );
    expect(refusal, contains('which is unchanged'));
    // And it names what to do next, rather than only stating the rule.
    expect(refusal, contains('Try a different destination for that step'));
  });

  test(
      'a drafted recipe opens carrying the account of the pass that composed '
      'it, and a Reload keeps it', () async {
    // The shape the dawn autopilot writes: its own draft, with the reasons it
    // recorded while composing. They used to reach the night report on disk and
    // nothing else, so this row's editor opened with none of them.
    final id = await recipes.create(
      masterId: null,
      baseMasterPath: _masterPath,
      name: 'Master · B draft',
      stepsJson: jsonEncode([_step('crop'), _step('stretch')]),
      createdBy: RecipeAuthor.autopilot,
      draftNotes: const [
        RecipeDraftNote(
          opId: 'color_calibrate',
          outcome: 'omitted',
          reason: 'this master has 1 channel(s) and the colour fit needs three',
        ),
        RecipeDraftNote(
          opId: 'crop',
          outcome: 'included',
          reason: 'measured from this master by the operation registry',
        ),
      ],
    );
    final scope = DarkroomScope.recipe(id);
    final opened = await settle(scope);

    expect(opened.draftNotes, hasLength(2));
    expect(opened.composedByRegistry, isTrue);
    // Only the decisions the stack cannot speak for itself are stated: the
    // `included` line repeats what its own step card already says.
    expect(opened.statedDraftNotes.single.opId, 'color_calibrate');
    expect(opened.draftNotesError, isNull);

    // Reload re-reads the row, which is where the account now lives.
    await container.read(darkroomControllerProvider(scope).notifier).refresh();
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final reloaded = container.read(darkroomControllerProvider(scope));
    expect(reloaded.statedDraftNotes.single.opId, 'color_calibrate');
    expect(reloaded.composedByRegistry, isTrue);
  });

  test('a recipe nobody drafted carries no account and claims none', () async {
    final id = await seedRecipe(steps: [_step('denoise')]);
    final state = await settle(DarkroomScope.recipe(id));
    expect(state.draftNotes, isEmpty);
    expect(state.composedByRegistry, isFalse);
    expect(state.draftNotesError, isNull);
  });

  test('a "Draft for me" recipe records that the registry composed it',
      () async {
    final masters = IntegratedMastersDao(db);
    final masterId = await masters.insertMaster(
      targetId: null,
      name: 'M31 B',
      masterFitsPath: _masterPath,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      channels: 1,
      width: 1024,
      height: 1024,
      frameCount: 8,
      totalIntegrationSeconds: 2400,
      settingsJson: '{}',
    );
    darkroom.draftSteps = [_step('crop'), _step('stretch')];
    darkroom.draftNotes = [
      {
        'opId': 'color_calibrate',
        'outcome': 'omitted',
        'reason': 'this master has 1 channel(s)',
      },
    ];

    final scope = DarkroomScope.master(masterId);
    await settle(scope);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );
    await controller.draftForMe();
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    final created = (await recipes.listForMaster(_masterPath)).single;
    // The operator asked for it, so the row records them as its creator; what
    // COMPOSED the steps is the account beside it.
    expect(created.createdBy, RecipeAuthor.user);
    final stored = await recipes.draftNotesOf(created.id!);
    expect(stored.map((n) => n.opId), [
      'color_calibrate',
      'crop',
      'stretch',
    ]);
    final state = container.read(darkroomControllerProvider(scope));
    expect(state.composedByRegistry, isTrue);
    expect(state.statedDraftNotes.single.opId, 'color_calibrate');
  });

  test('a master whose only recipe is deleted offers a start naming no recipe',
      () async {
    final masters = IntegratedMastersDao(db);
    final masterId = await masters.insertMaster(
      targetId: null,
      name: 'M31 B',
      masterFitsPath: _masterPath,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      channels: 1,
      width: 1024,
      height: 1024,
      frameCount: 8,
      totalIntegrationSeconds: 2400,
      settingsJson: '{}',
      statsJson: '{}',
    );
    final recipeId = await recipes.create(
      masterId: masterId,
      baseMasterPath: _masterPath,
      name: 'M31 B draft',
      stepsJson: jsonEncode([_step('crop'), _step('stretch')]),
      createdBy: RecipeAuthor.autopilot,
    );
    final scope = DarkroomScope.master(masterId);
    final opened = await settle(scope);
    expect(opened.recipeName, 'M31 B draft');
    expect(opened.steps, hasLength(2));

    await recipes.deleteRecipe(recipeId);
    final controller = container.read(
      darkroomControllerProvider(scope).notifier,
    );
    await controller.refresh();
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    final offered = container.read(darkroomControllerProvider(scope));
    expect(offered.offer, isNotNull);
    expect(offered.offer!.masterName, 'M31 B');
    // Nothing of the deleted recipe survives: the header reads its NAME off
    // this state, and it printed "M31 B draft" over the subtitle "No recipe
    // yet" for as long as copyWith carried these fields through.
    expect(offered.hasRecipe, isFalse);
    expect(offered.recipeId, isNull);
    expect(offered.recipeName, isEmpty);
    expect(offered.steps, isEmpty);
    expect(offered.reports, isEmpty);
    expect(offered.preview, isNull);
    // The catalogue is about this build's registry, not about any recipe.
    expect(offered.catalog, isNotNull);
  });

  test('a malformed step is named the way the editor would number it', () {
    // The FIRST entry of the array is "step 1" — the same step the cards, the
    // move buttons and the engine's own refusals all call 1. It read "step 0"
    // for as long as the message printed the array index it was handed.
    expect(
      () =>
          DarkroomStep.fromJson(const <String, dynamic>{'opId': 123}, index: 0),
      throwsA(
        isA<DarkroomRecipeFormatException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('step 1 names no operation'),
            isNot(contains('step 0')),
          ),
        ),
      ),
    );
    expect(
      () => DarkroomStep.fromJson('juststring', index: 1),
      throwsA(
        isA<DarkroomRecipeFormatException>().having(
          (e) => e.message,
          'message',
          contains('step 2 is a JSON string'),
        ),
      ),
    );
    expect(
      () => DarkroomStep.fromJson(
        const <String, dynamic>{'opId': 'crop', 'opVersion': 'one'},
        index: 3,
      ),
      throwsA(
        isA<DarkroomRecipeFormatException>().having(
          (e) => e.message,
          'message',
          contains('step 4 (crop) carries no integer "opVersion"'),
        ),
      ),
    );
    expect(
      () => DarkroomStep.fromJson(
        const <String, dynamic>{'opId': 'crop', 'opVersion': 1},
        index: 3,
      ),
      throwsA(
        isA<DarkroomRecipeFormatException>().having(
          (e) => e.message,
          'message',
          contains('step 4 (crop) carries no boolean "enabled"'),
        ),
      ),
    );
  });
}
