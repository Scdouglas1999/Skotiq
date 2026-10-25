// The Darkroom editor's one edit that puts an operation INTO a recipe.
//
// "Start from linear" writes an empty recipe and its own offer promises that
// "nothing is applied until you add a step" — and until this control existed
// there was no way to add one: the controller exposed toggle, set-param,
// remove, reorder, reset and undo, and the screen's twenty buttons carried no
// add. A recipe started that way could only be imported over or deleted.
//
// What is asserted here is what a reader of the code cannot see:
//
//  * where a step lands, against the engine's own stage rule, at each boundary;
//  * that a refused insert stays refused, with the engine's sentence, and never
//    reaches the renderer;
//  * that an accepted insert renders WITH the new step and one undo restores
//    the exact steps_json the row held before it;
//  * that an operation whose required parameter has no documented default opens
//    on the registry's measurement of this master, and is refused with the
//    registry's own note when there is no measurement to open on;
//  * that the chooser states where each operation would go, disables what this
//    build cannot place, and names its parameter fields for a screen reader.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_controller.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart' show TestBackendNotifier;
import '../../harness/mock_backend.dart';
import '../../harness/mock_database.dart';

const String _masterPath = '/tmp/skotiq-test/m31_G.fits';

/// A Darkroom seam whose every reply the test writes.
class _ScriptedDarkroom implements DarkroomSeam {
  /// Whether `validate` accepts the stack it is handed.
  bool validateOk = true;

  /// The whole-recipe sentence a refusal carries.
  ///
  /// Word for word what `RecipeError::StageOrder` prints, which counts the
  /// recipe it was handed from 1: the insert makes `[stretch, denoise]`, so
  /// denoise is step 2 and stretch step 1.
  String validateError =
      'step 2 (denoise@1) is a linear-stage operation but step 1 (stretch) '
      'already left the linear stage';

  /// Steps the registry's measured draft of this master carries.
  List<Map<String, dynamic>> draftSteps = const [];

  /// The notes it recorded about the operations that draft does NOT carry.
  List<Map<String, dynamic>> draftNotes = const [];

  /// When set, an operation the catalogue publishes with a stage token this
  /// build does not model.
  bool publishUnmodelledOp = false;

  /// When set, the catalogue also publishes `color_calibrate` — the operation
  /// the engine defines a result for on three channels only.
  bool publishColorCalibrate = false;

  final List<String> validated = [];
  final List<String> previewRecipes = [];
  final List<Map<String, dynamic>> registryCalls = [];

  int get previewCount => previewRecipes.length;

  /// The `opId`s of the last render request, in order.
  List<String> get lastRendered {
    final steps = (jsonDecode(previewRecipes.last)
        as Map<String, dynamic>)['steps'] as List;
    return [
      for (final step in steps)
        (step as Map<String, dynamic>)['opId'] as String,
    ];
  }

  @override
  Future<Map<String, dynamic>> validate({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    validated.add(recipeJson);
    final steps =
        (jsonDecode(recipeJson) as Map<String, dynamic>)['steps'] as List;
    return {
      'ok': validateOk,
      'error': validateOk ? null : validateError,
      'steps': [
        for (var i = 0; i < steps.length; i++)
          {
            'index': i,
            'opId': (steps[i] as Map<String, dynamic>)['opId'],
            'opVersion': (steps[i] as Map<String, dynamic>)['opVersion'],
            'enabled': (steps[i] as Map<String, dynamic>)['enabled'],
            'registered': true,
            'valid': true,
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
    final steps =
        (jsonDecode(recipeJson) as Map<String, dynamic>)['steps'] as List;
    return DarkroomRenderedPreview(
      width: 2,
      height: 2,
      isColor: false,
      rgba: Uint8List(2 * 2 * 4),
      report: {
        'encoding': {'applied': 'unit', 'sourceDomain': 'stretched'},
        'level': {'level': 0, 'scaleFromMaster': 1.0},
        'report': {
          'steps': [
            for (var i = 0; i < steps.length; i++)
              {
                'index': i,
                'opId': (steps[i] as Map<String, dynamic>)['opId'],
                'outcome':
                    ((steps[i] as Map<String, dynamic>)['enabled'] as bool)
                        ? 'applied'
                        : 'disabled',
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
    throw StateError('these tests do not export');
  }

  @override
  Future<Map<String, dynamic>> registry(Map<String, dynamic> args) async {
    registryCalls.add(args);
    final catalogue = <String, dynamic>{
      'schemaVersion': 1,
      'ops': [
        {
          'id': 'crop',
          'version': 1,
          'stage': 'linear',
          'summary': 'Cuts a rectangle out of the frame.',
          'params': [
            {
              'name': 'x',
              'displayName': 'Left edge (master pixels)',
              'kind': 'integer',
              'required': false,
              'min': 0.0,
              'max': 1000000.0,
              'default': 0,
              'independent': true,
              'summary': 'Left edge in master pixels.',
            },
            // Required with NO documented default: the engine refuses the step
            // without it, and nothing in this editor may invent one.
            {
              'name': 'width',
              'displayName': 'Width (master pixels)',
              'kind': 'integer',
              'required': true,
              'min': 1.0,
              'max': 1000000.0,
              'independent': true,
              'summary': 'Rectangle width in master pixels.',
            },
          ],
        },
        {
          'id': 'denoise',
          'version': 1,
          'stage': 'linear',
          'summary': 'Shrinks wavelet detail.',
          'params': [
            {
              'name': 'strength',
              'displayName': 'Strength',
              'kind': 'number',
              'required': false,
              'min': 0.0,
              'max': 1.0,
              'default': 0.5,
              'independent': true,
              'summary': 'How much detail is shrunk.',
            },
          ],
        },
        {
          'id': 'stretch',
          'version': 1,
          'stage': 'stretched',
          'summary': 'Generalised hyperbolic stretch.',
          'params': [
            {
              'name': 'd',
              'displayName': 'Stretch intensity',
              'kind': 'number',
              'required': false,
              'min': 0.0,
              'max': 100.0,
              'default': 1.0,
              'independent': true,
              'summary': 'Stretch intensity; 0 is the identity ramp.',
            },
            {
              'name': 'blackPoint',
              'displayName': 'Black point (ADU)',
              'kind': 'number',
              'required': true,
              'min': -1e12,
              'max': 1e12,
              'independent': false,
              'summary': 'ADU mapped to 0.',
            },
          ],
        },
        if (publishUnmodelledOp)
          {
            'id': 'sharpen',
            'version': 1,
            'stage': 'perceptual',
            'summary': 'Sharpens, in a stage this build does not model.',
            'params': const <dynamic>[],
          },
        if (publishColorCalibrate)
          {
            'id': 'color_calibrate',
            'version': 1,
            'stage': 'linear',
            'summary': 'Fits a B−V colour-versus-flux regression.',
            'params': const <dynamic>[],
          },
      ],
    };
    if (args['masterPath'] == null || (args['masterPath'] as String).isEmpty) {
      return catalogue;
    }
    return {
      ...catalogue,
      'draft': {
        'recipe': {'steps': draftSteps},
        'notes': draftNotes,
      },
    };
  }

  @override
  Future<Map<String, dynamic>> cancel(Map<String, dynamic> args) async =>
      {'renderId': args['renderId'], 'running': false};
}

DawnPhotometryResolver _emptyPhotometry() {
  return DawnPhotometryResolver(
    coneSearch: (center, radiusDegrees, {maxMagnitude}) async => const [],
  );
}

Map<String, dynamic> _step(
  String opId, {
  bool enabled = true,
  int opVersion = 1,
  Map<String, dynamic> params = const <String, dynamic>{},
}) =>
    {
      'opId': opId,
      'opVersion': opVersion,
      'params': params,
      'enabled': enabled,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ScriptedDarkroom darkroom;
  late ProviderContainer container;
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
    recipes = container.read(recipesDaoProvider);
  });

  Future<int> seedRecipe({
    List<Map<String, dynamic>> steps = const [],
    String name = 'Linear',
  }) {
    return recipes.create(
      masterId: null,
      baseMasterPath: _masterPath,
      name: name,
      stepsJson: jsonEncode(steps),
      createdBy: RecipeAuthor.user,
    );
  }

  void open(DarkroomScope scope) {
    container.listen<DarkroomState>(
      darkroomControllerProvider(scope),
      (_, __) {},
      fireImmediately: true,
    );
  }

  Future<DarkroomState> settle(DarkroomScope scope) async {
    open(scope);
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    return container.read(darkroomControllerProvider(scope));
  }

  Future<void> pumpDebounces() async {
    await Future<void>.delayed(
      kDarkroomSaveDebounce + const Duration(milliseconds: 80),
    );
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// The catalogue entry for [opId], as the open editor holds it.
  DarkroomOpSpec opSpec(DarkroomController controller, String opId) {
    return controller.state.catalog!.ops.firstWhere((op) => op.id == opId);
  }

  DarkroomController controllerFor(DarkroomScope scope) =>
      container.read(darkroomControllerProvider(scope).notifier);

  // -------------------------------------------------------------------
  // Where a step lands: the engine's stage rule, at each boundary
  // -------------------------------------------------------------------

  test('the first step of an empty recipe is added, rendered and stored',
      () async {
    final id = await seedRecipe();
    final scope = DarkroomScope.recipe(id);
    final state = await settle(scope);
    expect(state.steps, isEmpty);
    final controller = controllerFor(scope);
    final renders = darkroom.previewCount;

    final added = await controller.insertStep(opSpec(controller, 'denoise'));
    expect(added, isTrue);
    expect(controller.state.steps.map((s) => s.opId), ['denoise']);
    // The operation's own documented defaults are left to it: an absent key is
    // what lets an improved default reach a recipe written today.
    expect(controller.state.steps.single.params, isEmpty);
    expect(controller.state.steps.single.enabled, isTrue);

    await pumpDebounces();
    // The render that follows replays the stack WITH the new step, and the
    // report it comes back with is about that step — an added step that never
    // reached the engine would leave the card with no outcome to show.
    expect(darkroom.previewCount, greaterThan(renders));
    expect(darkroom.lastRendered, ['denoise']);
    expect(
      controller.state.reportFor(0)?.outcome,
      DarkroomStepOutcome.applied,
    );
    // And the row carries it, so the next launch opens on the same stack.
    final stored = await recipes.getById(id);
    expect(jsonDecode(stored!.stepsJson), hasLength(1));
    expect((jsonDecode(stored.stepsJson) as List).first['opId'], 'denoise');
  });

  test('a linear operation lands ahead of the first stretched step', () async {
    final id = await seedRecipe(steps: [
      _step('stretch', params: {'blackPoint': 12.0}),
    ]);
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = controllerFor(scope);

    expect(await controller.insertStep(opSpec(controller, 'denoise')), isTrue);
    // Not appended: a linear-stage operation cannot run after a stretched one,
    // and the last place the rule leaves for it is in front of the stretch.
    expect(controller.state.steps.map((s) => s.opId), ['denoise', 'stretch']);
  });

  test('a stretched operation lands at the end of the stack', () async {
    final id = await seedRecipe(steps: [_step('denoise')]);
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = controllerFor(scope);
    darkroom.draftSteps = [
      _step('stretch', params: {'blackPoint': 529.7, 'd': 1.938}),
    ];

    expect(await controller.insertStep(opSpec(controller, 'stretch')), isTrue);
    expect(controller.state.steps.map((s) => s.opId), ['denoise', 'stretch']);
  });

  test('a linear operation lands after the linear steps already in the stack',
      () async {
    final id = await seedRecipe(steps: [
      _step('denoise'),
      _step('stretch', params: {'blackPoint': 12.0}),
    ]);
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = controllerFor(scope);
    darkroom.draftSteps = [
      _step('crop', params: {'x': 4, 'width': 60}),
    ];

    expect(await controller.insertStep(opSpec(controller, 'crop')), isTrue);
    expect(controller.state.steps.map((s) => s.opId), [
      'denoise',
      'crop',
      'stretch',
    ]);
  });

  test('a disabled stretched step still holds the stage boundary', () async {
    // The engine's rule reads the whole recipe, switched-off steps included:
    // `validate` orders every REGISTERED step by its stage whatever its enabled
    // flag says. Proposing a linear step after a disabled stretch would be an
    // order the engine refuses.
    final id = await seedRecipe(steps: [
      _step('stretch', params: {'blackPoint': 12.0}, enabled: false),
    ]);
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = controllerFor(scope);

    expect(await controller.insertStep(opSpec(controller, 'denoise')), isTrue);
    expect(controller.state.steps.map((s) => s.opId), ['denoise', 'stretch']);
  });

  // -------------------------------------------------------------------
  // A refusal is a refusal: nothing added, the engine's own sentence
  // -------------------------------------------------------------------

  test('an insert the engine refuses adds nothing and states why', () async {
    final id = await seedRecipe(steps: [_step('denoise')]);
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = controllerFor(scope);
    await pumpDebounces();
    final renders = darkroom.previewCount;

    darkroom.validateOk = false;
    darkroom.draftSteps = [
      _step('stretch', params: {'blackPoint': 529.7}),
    ];
    final added = await controller.insertStep(opSpec(controller, 'stretch'));

    expect(added, isFalse);
    expect(controller.state.steps.map((s) => s.opId), ['denoise']);
    final refusal = controller.state.insertRefusal!;
    expect(refusal, contains('already left the linear stage'));
    expect(refusal, contains('the step was not added'));
    // Counted from 1 over the stack the insert was asking for, as the refused
    // move's sentence is — the engine's own numbers, carried through and told
    // which arrangement they count.
    expect(refusal, contains('step 2 (denoise@1)'));
    expect(refusal, contains('step 1 (stretch)'));
    expect(
      refusal,
      contains('count the stack the added step would have produced, from 1'),
    );

    // A refused stack never reaches the renderer.
    await pumpDebounces();
    expect(darkroom.previewCount, renders);
    // And it is not written to the row either.
    final stored = await recipes.getById(id);
    expect(jsonDecode(stored!.stepsJson), hasLength(1));
  });

  test('one undo restores the exact step list the insert changed', () async {
    final id = await seedRecipe(steps: [_step('denoise')]);
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = controllerFor(scope);
    await pumpDebounces();
    final before = (await recipes.getById(id))!.stepsJson;

    expect(await controller.insertStep(opSpec(controller, 'denoise')), isTrue);
    expect(controller.state.steps, hasLength(2));
    expect(controller.state.canUndo, isTrue);
    await pumpDebounces();
    expect((await recipes.getById(id))!.stepsJson, isNot(before));

    controller.undo();
    expect(controller.state.steps.map((s) => s.opId), ['denoise']);
    await pumpDebounces();
    expect((await recipes.getById(id))!.stepsJson, before);

    // And redo puts it back, so the insert is an ordinary journalled edit.
    controller.redo();
    expect(controller.state.steps, hasLength(2));
  });

  // -------------------------------------------------------------------
  // Opening parameters: measured, or refused with the registry's reason
  // -------------------------------------------------------------------

  test(
      'a required parameter with no default opens on the registry\'s own '
      'measurement of this master', () async {
    final id = await seedRecipe();
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = controllerFor(scope);
    darkroom.draftSteps = [
      _step('crop', params: {'x': 8, 'y': 12, 'width': 900, 'height': 600}),
    ];

    expect(await controller.insertStep(opSpec(controller, 'crop')), isTrue);
    final step = controller.state.steps.single;
    expect(step.opId, 'crop');
    // Exactly the numbers the registry measured — nothing rounded, nothing
    // filled in here.
    expect(step.params['width'], 900);
    expect(step.params['height'], 600);
    expect(step.params['x'], 8);
    // The measurement was asked for over this recipe's own base master.
    expect(
      darkroom.registryCalls.last['masterPath'],
      _masterPath,
    );
  });

  test(
      'an operation the registry could not measure is refused in the '
      'registry\'s own words', () async {
    final id = await seedRecipe();
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = controllerFor(scope);
    // The measured draft carries no crop, and says why.
    darkroom.draftSteps = [_step('denoise')];
    darkroom.draftNotes = [
      {
        'opId': 'crop',
        'outcome': 'omitted',
        'reason': 'no fully covered rectangle survives in this master, so no '
            'crop is proposed',
      },
    ];

    final added = await controller.insertStep(opSpec(controller, 'crop'));
    expect(added, isFalse);
    expect(controller.state.steps, isEmpty);
    final refusal = controller.state.insertRefusal!;
    expect(refusal, contains('no fully covered rectangle survives'));
    expect(refusal, contains('Width (master pixels)'));
    expect(refusal, contains('no documented default'));
  });

  test('a registry that cannot read the master refuses with its own message',
      () async {
    final id = await seedRecipe();
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = controllerFor(scope);
    darkroom.draftSteps = const [];
    darkroom.draftNotes = const [];

    final added = await controller.insertStep(opSpec(controller, 'crop'));
    expect(added, isFalse);
    expect(controller.state.steps, isEmpty);
    // No note, no measurement: the refusal says exactly that, rather than
    // opening the step on a rectangle nothing measured.
    expect(
      controller.state.insertRefusal,
      contains('carries no Crop step and states no reason'),
    );
  });

  test(
      'an operation whose stage this build does not model is refused, and the '
      'engine is never asked', () async {
    darkroom.publishUnmodelledOp = true;
    final id = await seedRecipe();
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = controllerFor(scope);
    final validations = darkroom.validated.length;

    final added = await controller.insertStep(opSpec(controller, 'sharpen'));
    expect(added, isFalse);
    expect(controller.state.steps, isEmpty);
    expect(controller.state.insertRefusal, contains('"perceptual"'));
    expect(
      controller.state.insertRefusal,
      contains('this build does not model'),
    );
    expect(darkroom.validated.length, validations);
  });

  test('the next edit clears the refusal the last insert left', () async {
    final id = await seedRecipe(steps: [_step('denoise')]);
    final scope = DarkroomScope.recipe(id);
    await settle(scope);
    final controller = controllerFor(scope);

    darkroom.validateOk = false;
    await controller.insertStep(opSpec(controller, 'denoise'));
    expect(controller.state.insertRefusal, isNotNull);

    darkroom.validateOk = true;
    controller.toggleStep(0);
    expect(controller.state.insertRefusal, isNull);
  });

  // -------------------------------------------------------------------
  // The chooser on screen
  // -------------------------------------------------------------------

  group('the editor screen', () {
    late SkotiqDatabase db;
    late RecipesDao screenRecipes;

    setUp(() {
      db = mockDatabase();
      screenRecipes = RecipesDao(db);
    });

    tearDown(() async {
      await db.close();
    });

    Future<int> seedScreenRecipe(List<Map<String, dynamic>> steps) {
      return screenRecipes.create(
        masterId: null,
        baseMasterPath: _masterPath,
        name: 'Linear',
        stepsJson: jsonEncode(steps),
        createdBy: RecipeAuthor.user,
      );
    }

    Future<void> pump(
      WidgetTester tester, {
      required int recipeId,
      Size size = const Size(1400, 1200),
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final screenContainer = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => TestBackendNotifier(ref, mockBackend()),
          ),
          databaseProvider.overrideWithValue(db),
          appVersionProvider.overrideWithValue(
            const AppVersionInfo(version: '0.0.0-test', buildNumber: 0),
          ),
          darkroomSeamProvider.overrideWithValue(darkroom),
          dawnPhotometryResolverProvider.overrideWithValue(_emptyPhotometry()),
        ],
      );
      addTearDown(screenContainer.dispose);

      final router = GoRouter(
        initialLocation: '/darkroom?recipe=$recipeId',
        routes: [
          GoRoute(
            path: '/analytics',
            builder: (context, state) => const Scaffold(
              body: Center(child: Text('session review stands in here')),
            ),
          ),
          GoRoute(
            path: '/darkroom',
            builder: (context, state) => DarkroomScreen(
              scope: DarkroomScope.recipe(
                int.parse(state.uri.queryParameters['recipe']!),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: screenContainer,
          child: MaterialApp.router(
            theme: SkotiqTheme.dark,
            routerConfig: router,
          ),
        ),
      );
      for (var i = 0; i < 14; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
    }

    Future<void> settleScreen(WidgetTester tester) async {
      for (var i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
    }

    Future<void> drain(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 600));
      }
    }

    testWidgets('an empty recipe offers the control its empty state points at',
        (tester) async {
      final id = await seedScreenRecipe(const []);
      await pump(tester, recipeId: id);

      expect(find.byKey(const ValueKey('darkroom_add_step')), findsOneWidget);
      // The empty state names the control rather than describing a dead end.
      expect(
        find.textContaining('"Add step", above, lists every operation'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('darkroom_add_step')));
      await settleScreen(tester);

      // Every registered operation is offered, with where it would go.
      expect(find.text('Add a step'), findsOneWidget);
      expect(find.widgetWithText(SkotiqButton, 'Denoise'), findsOneWidget);
      expect(find.widgetWithText(SkotiqButton, 'Stretch'), findsOneWidget);
      expect(
        find.textContaining('Goes in as the first step of the stack'),
        findsWidgets,
      );
      // And each of the two operations with a parameter this build documents
      // no default for says the registry has to measure this master first.
      expect(
        find.textContaining('asks the registry to measure this master first'),
        findsNWidgets(2),
      );

      await tester.tap(find.widgetWithText(SkotiqButton, 'Denoise'));
      await settleScreen(tester);
      await drain(tester);

      // The step is in the stack, on its own card.
      expect(find.text('Denoise'), findsOneWidget);
      final stored = await screenRecipes.getById(id);
      expect(
        (jsonDecode(stored!.stepsJson) as List).single['opId'],
        'denoise',
      );
    });

    testWidgets('the chooser states where a linear operation would go',
        (tester) async {
      final id = await seedScreenRecipe([
        _step('stretch', params: {'blackPoint': 12.0}),
      ]);
      await pump(tester, recipeId: id);
      await tester.tap(find.byKey(const ValueKey('darkroom_add_step')));
      await settleScreen(tester);

      // Both linear operations land in front of the stretch that is already
      // there; the stretched one goes on the end.
      expect(
        find.textContaining('Goes in as step 1, ahead of Stretch'),
        findsNWidgets(2),
      );
      expect(
        find.textContaining('Goes in at the end of the stack, as step 2'),
        findsOneWidget,
      );
      await drain(tester);
    });

    testWidgets(
        'an operation this build cannot place is disabled with its '
        'reason, not hidden', (tester) async {
      darkroom.publishUnmodelledOp = true;
      final id = await seedScreenRecipe(const []);
      await pump(tester, recipeId: id);
      await tester.tap(find.byKey(const ValueKey('darkroom_add_step')));
      await settleScreen(tester);

      // Listed — an operator looking for it has to be able to see what is in
      // the way — and refused, with the token the registry published.
      final entry = find.widgetWithText(SkotiqButton, 'Sharpen');
      expect(entry, findsOneWidget);
      expect(tester.widget<SkotiqButton>(entry).onPressed, isNull);
      expect(
        find.textContaining('which this build does not model'),
        findsOneWidget,
      );
      await drain(tester);
    });

    testWidgets(
        'a stack the engine already refuses disables the control and '
        'says so', (tester) async {
      darkroom.validateOk = false;
      darkroom.validateError = 'step 1 (crop@1) refuses its parameters: width '
          'must be at least 1';
      final id = await seedScreenRecipe([_step('crop')]);
      await pump(tester, recipeId: id);
      await settleScreen(tester);

      final control = find.byKey(const ValueKey('darkroom_add_step'));
      expect(control, findsOneWidget);
      expect(tester.widget<SkotiqButton>(control).onPressed, isNull);
      await drain(tester);
    });

    testWidgets('a refused insert states the refusal beside the stack',
        (tester) async {
      final id = await seedScreenRecipe([_step('denoise')]);
      await pump(tester, recipeId: id);
      await settleScreen(tester);

      darkroom.validateOk = false;
      await tester.tap(find.byKey(const ValueKey('darkroom_add_step')));
      await settleScreen(tester);
      await tester.tap(find.widgetWithText(SkotiqButton, 'Denoise'));
      await settleScreen(tester);

      expect(
        find.byKey(const ValueKey('darkroom_insert_refusal')),
        findsOneWidget,
      );
      expect(find.textContaining('That step was not added', findRichText: true),
          findsOneWidget);
      await drain(tester);
    });

    testWidgets('the chooser fits the narrowest window the editor opens in',
        (tester) async {
      // 430 logical pixels: the phone width where a Row of an operation name
      // and two tags would have overflowed its box, and where this screen
      // segments its three panels instead of laying them side by side.
      final id = await seedScreenRecipe(const []);
      await pump(tester, recipeId: id, size: const Size(430, 900));
      await tester.tap(find.text('History'));
      await settleScreen(tester);

      await tester.tap(find.byKey(const ValueKey('darkroom_add_step')));
      await settleScreen(tester);

      expect(find.text('Add a step'), findsOneWidget);
      expect(find.widgetWithText(SkotiqButton, 'Denoise'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('every parameter field names the parameter it edits',
        (tester) async {
      final handle = tester.ensureSemantics();
      final id = await seedScreenRecipe([
        _step('stretch', params: {'blackPoint': 529.7, 'd': 1.938}),
      ]);
      await pump(tester, recipeId: id);
      await tester.tap(find.text('Parameters'));
      await settleScreen(tester);

      // The slider's typed field READS "Exact" beside the slider it belongs to
      // — and publishes the parameter it is about, because a screen reader
      // walks three sibling fields with no column to read them in.
      expect(find.text('Exact'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Exact value for Stretch intensity'),
        findsOneWidget,
      );
      // The wide-ranged parameter's field carries the bounds alone: its name is
      // already the row's title, and printing it again under that title is the
      // same words three times over.
      expect(find.text('Black point (ADU)'), findsOneWidget);
      expect(
        find.text('no practical limit; the engine refuses past ±1.00e+12'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Black point (ADU) (no practical limit; the engine refuses past '
          '±1.00e+12)',
        ),
        findsOneWidget,
      );
      await drain(tester);
      handle.dispose();
    });

    testWidgets(
        'a bound the engine keeps as a guard is stated as one, not as a range',
        (tester) async {
      final handle = tester.ensureSemantics();
      final id = await seedScreenRecipe([
        _step('stretch', params: {'blackPoint': 529.7, 'd': 1.938}),
      ]);
      await pump(tester, recipeId: id);
      await tester.tap(find.text('Parameters'));
      await settleScreen(tester);

      // ±1e12 ADU is the engine's guard against a nonsense number, not a range
      // any master's data occupies. Printed bare beside a measured 529.751 it
      // read as the range the operator was choosing within.
      expect(find.textContaining('accepts -1.00e+12'), findsNothing);
      expect(
        find.text('no practical limit; the engine refuses past ±1.00e+12'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(
          'Black point (ADU) (no practical limit; the engine refuses past '
          '±1.00e+12)',
        ),
        findsOneWidget,
      );
      await drain(tester);
      handle.dispose();
    });

    testWidgets(
        'a stored double is read out rounded and revealed in full to edit',
        (tester) async {
      // The autopilot's own measured black point, to the last digit the row
      // holds. The box echoed it verbatim — 529.7506799121094 — beside sliders
      // that all read out to three decimals.
      const stored = 529.7506799121094;
      final id = await seedScreenRecipe([
        _step('stretch', params: {'blackPoint': stored, 'd': 1.938}),
      ]);
      await pump(tester, recipeId: id);
      await tester.tap(find.text('Parameters'));
      await settleScreen(tester);

      expect(find.text('529.751'), findsOneWidget);
      expect(find.text('$stored'), findsNothing);

      // A field being edited shows what the recipe HOLDS: an edit that started
      // from a rounded reading would write a number the operator never chose.
      await tester.ensureVisible(find.text('529.751'));
      await settleScreen(tester);
      await tester.tap(find.text('529.751'));
      await settleScreen(tester);
      expect(find.text('$stored'), findsOneWidget);

      // Focus moves to the intensity's own box; the black point goes back to
      // reading itself out, still holding what it held.
      await tester.tap(find.widgetWithText(SkotiqTextField, '1.938'));
      await settleScreen(tester);
      expect(find.text('529.751'), findsOneWidget);
      expect(find.text('$stored'), findsNothing);

      // And moving through the field wrote nothing — the row still carries
      // every digit of a value the operator never typed into.
      final row = await screenRecipes.getById(id);
      final steps = jsonDecode(row!.stepsJson) as List;
      final stretch = steps.firstWhere(
        (s) => (s as Map<String, dynamic>)['opId'] == 'stretch',
      ) as Map<String, dynamic>;
      expect(
        (stretch['params'] as Map<String, dynamic>)['blackPoint'],
        stored,
      );
      await drain(tester);
    });

    testWidgets(
        'the chooser publishes its title, its close and each operation as '
        'separate nodes', (tester) async {
      final id = await seedScreenRecipe(const []);
      await pump(tester, recipeId: id);
      final handle = tester.ensureSemantics();

      await tester.tap(find.byKey(const ValueKey('darkroom_add_step')));
      await settleScreen(tester);

      // The whole chooser reached AT-SPI as ONE button named "Add a step /
      // Close dialog", with the description and every operation nested inside
      // it: the title was readable only as part of a control's name, and the
      // control that closes the dialog had no node of its own to activate.
      String? labelled(String label) {
        for (final node in _traversal(tester)) {
          if (node.getSemanticsData().label == label) return label;
        }
        return null;
      }

      final title = _dataLabelled(tester, 'Add a step');
      expect(title, isNotNull, reason: 'the title has to read as text');
      expect(title!.flagsCollection.isButton, isFalse);

      final close = _dataLabelled(tester, 'Close dialog');
      expect(close, isNotNull);
      expect(close!.flagsCollection.isButton, isTrue);
      expect(labelled('Close dialog'), isNotNull);

      // And each operation keeps the node it always had.
      expect(
        find.bySemanticsLabel(RegExp('^Add Denoise v1 — Linear stage')),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(SkotiqButton, 'Close'));
      await settleScreen(tester);
      expect(find.text('Add a step'), findsNothing);
      handle.dispose();
      await drain(tester);
    });

    testWidgets(
        'a three-channel operation is refused over a mono master before it '
        'is added', (tester) async {
      darkroom.publishColorCalibrate = true;
      final masterId = await IntegratedMastersDao(db).insertMaster(
        targetId: null,
        name: 'M31 G',
        masterFitsPath: _masterPath,
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.batch,
        channels: 1,
        width: 64,
        height: 64,
        frameCount: 8,
        totalIntegrationSeconds: 2400,
        settingsJson: '{}',
        statsJson: '{}',
      );
      final id = await screenRecipes.create(
        masterId: masterId,
        baseMasterPath: _masterPath,
        name: 'Linear',
        stepsJson: jsonEncode([_step('denoise')]),
        createdBy: RecipeAuthor.user,
      );
      await pump(tester, recipeId: id);
      await settleScreen(tester);
      await tester.tap(find.byKey(const ValueKey('darkroom_add_step')));
      await settleScreen(tester);

      // Listed, never hidden — an operator looking for it has to see what is in
      // the way — and refused before the press, in the engine's own words. It
      // used to state its stage rule and its insertion index in full and say
      // nothing about channels: the step committed, the render came back
      // "unsupported channel layout", and the picture sat stale until the
      // operator found the step and removed it.
      final entry = find.widgetWithText(SkotiqButton, 'Color calibrate');
      expect(entry, findsOneWidget);
      expect(tester.widget<SkotiqButton>(entry).onPressed, isNull);
      expect(
        find.textContaining('This master has 1 channel and this operation '
            'runs over a colour master with 3 channels'),
        findsOneWidget,
      );
      // Denoise has no channel precondition, so it is still offered.
      expect(
        tester
            .widget<SkotiqButton>(
              find.widgetWithText(SkotiqButton, 'Denoise'),
            )
            .onPressed,
        isNotNull,
      );
      await drain(tester);
    });

    testWidgets('each operation is read once, not once per caption', (
      tester,
    ) async {
      // The entry's button composed its accessible name out of the same
      // sentences its sibling captions render, and nothing excluded those
      // captions — so a reader walking to the operation they want heard every
      // placement rule and every refusal twice, once as a control's name and
      // once as loose text beside it.
      final id = await seedScreenRecipe([_step('stretch')]);
      await pump(tester, recipeId: id);
      final handle = tester.ensureSemantics();

      await tester.tap(find.byKey(const ValueKey('darkroom_add_step')));
      await settleScreen(tester);

      const placement = 'Goes in as step 1, ahead of Stretch: a linear-stage '
          'operation cannot run after a stretched one, so this is the last '
          'place in the stack the rule leaves for it.';
      const summary = 'Shrinks wavelet detail.';

      // Still painted: this is an accessibility change, not a copy deletion.
      expect(find.text(placement), findsWidgets);
      expect(find.text(summary), findsOneWidget);

      final loose = [
        for (final node in _traversal(tester))
          if (node.getSemanticsData().label == placement ||
              node.getSemanticsData().label == summary)
            node.getSemanticsData().label,
      ];
      expect(
        loose,
        isEmpty,
        reason: 'the captions are the control\'s own name; published again as '
            'loose nodes they are read a second time',
      );

      // And the one node that IS the control carries every sentence its card
      // shows, so nothing was silenced to stop the repetition.
      final denoise =
          _dataLabelStartingWith(tester, RegExp('^Add Denoise v1 — '));
      expect(denoise, isNotNull);
      expect(denoise!.label, contains(summary));
      expect(denoise.label, contains(placement));
      handle.dispose();
      await drain(tester);
    });
  });
}

/// Every semantics node in the tree, in the order assistive tech walks it.
List<SemanticsNode> _traversal(WidgetTester tester) {
  final nodes = <SemanticsNode>[];
  void walk(SemanticsNode node) {
    nodes.add(node);
    for (final child in node.debugListChildrenInOrder(
      DebugSemanticsDumpOrder.traversalOrder,
    )) {
      walk(child);
    }
  }

  walk(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
  return nodes;
}

/// The node whose label matches [pattern], or null when none does.
SemanticsData? _dataLabelStartingWith(WidgetTester tester, Pattern pattern) {
  for (final node in _traversal(tester)) {
    final data = node.getSemanticsData();
    if (data.label.startsWith(pattern)) return data;
  }
  return null;
}

/// The node whose label is exactly [label], or null when none is.
SemanticsData? _dataLabelled(WidgetTester tester, String label) {
  for (final node in _traversal(tester)) {
    final data = node.getSemanticsData();
    if (data.label == label) return data;
  }
  return null;
}
