// Widget and unit tests for the Darkroom editor seams closed in wave 4.
//
// Each of these asserts a statement the screen makes — or a control it offers —
// that a reader of the code cannot see, and that was measurably absent from the
// running app before:
//
//  * the registry's draft NOTES reach the screen, so a mono master's draft says
//    the colour calibration was left out and why (the decoder had zero callers,
//    and the notes reached only the night report on disk);
//  * a cascade delete that takes the open recipe lands on the MASTER, and the
//    load failure blames nothing that is still on disk;
//  * every step card offers a keyboard-reachable move up / move down beside the
//    pointer-only drag handle;
//  * a slider-ranged parameter carries a typed field, so a working region
//    narrower than the track can resolve is reachable exactly;
//  * parameter controls are labelled with the registry's display name;
//  * an ENABLED export option publishes its rationale in its accessible name;
//  * the branch bar and the start offer name the night's other masters;
//  * Escape and Alt+Left leave, and a Back control says so;
//  * the delete confirmation names the child branches up front;
//  * compare keeps the Recipe and History panels reachable;
//  * a `.nsrecipe` sidecar can be read back into a recipe.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsFlag, SemanticsNode;
import 'package:flutter/services.dart';
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

const String _masterPath = '/tmp/skotiq-test/m31_B.fits';

/// A Darkroom seam whose every reply the test writes.
class _ScriptedDarkroom implements DarkroomSeam {
  /// The `notes` array the registry answers a draft request with.
  List<Map<String, dynamic>> draftNotes = const [];

  /// Steps the drafted recipe carries.
  List<Map<String, dynamic>> draftSteps = const [];

  /// `opId@opVersion` keys this scripted build does not register.
  Set<String> unregisteredOps = {};

  /// Every `validate` recipe payload, in call order.
  final List<String> validated = [];

  static String _opKey(Map<String, dynamic> step) =>
      '${step['opId']}@${step['opVersion']}';

  @override
  Future<Map<String, dynamic>> validate({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    validated.add(recipeJson);
    final steps =
        (jsonDecode(recipeJson) as Map<String, dynamic>)['steps'] as List;
    var bad = false;
    final entries = <Map<String, dynamic>>[];
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i] as Map<String, dynamic>;
      final known = !unregisteredOps.contains(_opKey(step));
      if (!known) bad = true;
      entries.add({
        'index': i,
        'registered': known,
        'valid': known,
        if (!known) 'error': 'no operation registered as ${_opKey(step)}',
      });
    }
    return {
      'ok': !bad,
      'error': bad ? 'a step names an operation this build does not run' : null,
      'steps': entries,
    };
  }

  @override
  Future<DarkroomRenderedPreview> renderPreview({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
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
    final catalogue = {
      'schemaVersion': 1,
      'ops': [
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
        {
          'id': 'denoise',
          'version': 1,
          'stage': 'linear',
          'summary': 'Shrinks wavelet detail.',
          'params': const <dynamic>[],
        },
        {
          'id': 'crop',
          'version': 1,
          'stage': 'linear',
          'summary': 'Cuts a rectangle out of the frame.',
          'params': const <dynamic>[],
        },
      ],
    };
    if (args['masterPath'] == null) return catalogue;
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
  late SkotiqDatabase db;
  late RecipesDao recipes;
  late IntegratedMastersDao masters;
  late ImagesDao images;

  /// What the scripted `.nsrecipe` chooser answers with, or null for a
  /// dismissed chooser.
  DarkroomSidecarPick? sidecarAnswer;
  var sidecarCalls = 0;

  setUp(() {
    darkroom = _ScriptedDarkroom();
    db = mockDatabase();
    recipes = RecipesDao(db);
    masters = IntegratedMastersDao(db);
    images = ImagesDao(db);
    sidecarAnswer = null;
    sidecarCalls = 0;
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedMaster({
    required String name,
    required String path,
    int channels = 1,
    String? filter,
  }) {
    return masters.insertMaster(
      targetId: null,
      name: name,
      masterFitsPath: path,
      status: IntegratedMasterStatus.finalized,
      accumulationMode: AccumulationMode.batch,
      channels: channels,
      width: 64,
      height: 64,
      frameCount: 3,
      totalIntegrationSeconds: 6,
      settingsJson: '{}',
      statsJson: '{}',
      filter: filter,
    );
  }

  Future<int> seedRecipe(
    List<Map<String, dynamic>> steps, {
    String name = 'Draft',
    int? masterId,
    String path = _masterPath,
    RecipeAuthor by = RecipeAuthor.autopilot,
  }) {
    return recipes.create(
      masterId: masterId,
      baseMasterPath: path,
      name: name,
      stepsJson: jsonEncode(steps),
      createdBy: by,
    );
  }

  /// Fold one frame of [sessionId] into [masterId], which is the only link the
  /// night walk follows back from a master to the session that produced it.
  ///
  /// The frame carries no file path on purpose: with one, the DAO stats the
  /// file to fill `file_size`, and real filesystem I/O inside a widget test's
  /// fake-async zone never completes — the future is simply never resolved and
  /// the test sits until its own timeout.
  Future<void> foldFrame(int masterId, int sessionId, String tag) async {
    final imageId = await images.insertSequenceFrame(
      filePath: '',
      fileName: '$tag.fits',
      fileFormat: 'fits',
      exposureDuration: 2.0,
      capturedAt: DateTime.utc(2026, 8, 17),
      isAccepted: true,
      producingNodeId: 'exp_$tag',
      sessionId: sessionId,
    );
    await masters.recordFoldedFrame(masterId: masterId, imageId: imageId);
  }

  Future<GoRouter> pump(
    WidgetTester tester, {
    required String location,
    Size size = const Size(1400, 1200),
    bool remoteClient = false,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final container = ProviderContainer(
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
        darkroomSidecarReaderProvider.overrideWithValue(() async {
          sidecarCalls++;
          return sidecarAnswer;
        }),
        if (remoteClient) remoteClientLaunchProvider.overrideWithValue(true),
      ],
    );
    addTearDown(container.dispose);

    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: '/analytics',
          builder: (context, state) => const Scaffold(
            body: Center(child: Text('session review stands in here')),
          ),
        ),
        GoRoute(
          path: '/darkroom',
          builder: (context, state) {
            final rawRecipe = state.uri.queryParameters['recipe'];
            final rawMaster = state.uri.queryParameters['master'];
            final recipeId = rawRecipe == null ? null : int.tryParse(rawRecipe);
            final masterId = rawMaster == null ? null : int.tryParse(rawMaster);
            return DarkroomScreen(
              scope: recipeId != null
                  ? DarkroomScope.recipe(recipeId)
                  : (masterId != null
                      ? DarkroomScope.master(masterId)
                      : const DarkroomScope.empty()),
            );
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: SkotiqTheme.dark,
          routerConfig: router,
        ),
      ),
    );
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    return router;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
  }

  // -------------------------------------------------------------------
  // D2-01 — the registry's draft notes reach the screen
  // -------------------------------------------------------------------

  test('the draft-note decoder reads the registry\'s own account', () {
    final notes = decodeDarkroomDraftNotes({
      'draft': {
        'notes': [
          {
            'opId': 'color_calibrate',
            'outcome': 'omitted',
            'reason': 'this master has 1 channel(s) and the colour fit needs '
                'three',
          },
          {'opId': 'stretch', 'outcome': 'omitted'},
          'not an object',
        ],
      },
    });
    expect(notes, hasLength(2));
    expect(notes.first.opId, 'color_calibrate');
    expect(notes.first.outcome, 'omitted');
    expect(notes.first.reason, contains('1 channel(s)'));
    // A note with no reason says the registry stated none, never invents one.
    expect(notes.last.reason, 'the operation registry stated no reason');
    // Printed, the operation is named the way its step card names it.
    expect(
      darkroomDraftNoteSentence(notes.first),
      startsWith('Color calibrate — omitted:'),
    );
  });

  test(
      'the composed account completes the registry\'s notes with the steps '
      'it did carry', () {
    final account = darkroomComposedAccount(
      [
        DarkroomStep.fromJson(_step('crop'), index: 0),
        DarkroomStep.fromJson(_step('stretch'), index: 1),
      ],
      const [
        RecipeDraftNote(
          opId: 'color_calibrate',
          outcome: 'omitted',
          reason: 'this master has 1 channel(s)',
        ),
      ],
    );
    // The omission keeps its own words, and every carried step is recorded as
    // included — which is what makes a note-carrying row a DRAFTED row even
    // when the draft left nothing out.
    expect(account.map((n) => n.opId), ['color_calibrate', 'crop', 'stretch']);
    expect(account.map((n) => n.outcome), ['omitted', 'included', 'included']);
  });

  testWidgets(
      'a mono master\'s draft states the colour step it left out, and why',
      (tester) async {
    final masterId = await seedMaster(name: 'Master · B', path: _masterPath);
    darkroom.draftSteps = [
      _step('crop'),
      _step('denoise'),
      _step('stretch', params: {'blackPoint': 529.7, 'd': 1.938}),
    ];
    darkroom.draftNotes = [
      {
        'opId': 'color_calibrate',
        'outcome': 'omitted',
        'reason': 'this master has 1 channel(s) and the colour fit needs '
            'three, so this draft covers the one channel it was given',
      },
    ];

    await pump(tester, location: '/darkroom?master=$masterId');
    expect(find.text('Master · B has no recipe yet'), findsOneWidget);
    // The offer no longer promises colour on a master that has one channel.
    expect(
      find.textContaining('no colour calibration, because the fit needs three'),
      findsOneWidget,
    );

    await tester.tap(find.text('Draft for me'));
    await settle(tester);

    // The stack the registry did carry.
    expect(find.text('Stretch'), findsOneWidget);
    // And the operation it decided about and did not carry, with its reason —
    // which used to reach the night report on disk and nothing else.
    expect(
        find.textContaining('The draft left one operation out',
            findRichText: true),
        findsOneWidget);
    expect(
      find.textContaining('the colour fit needs three'),
      findsOneWidget,
    );
    // Named the way the step cards name operations, not as the wire id.
    expect(find.textContaining('Color calibrate — omitted:'), findsOneWidget);
    expect(find.textContaining('color_calibrate —'), findsNothing);
    // The registry composed these steps, so the tag says drafted rather than
    // crediting the operator with a stack they did not choose.
    expect(find.text('Drafted at your request'), findsOneWidget);
    expect(find.text('Written by you'), findsNothing);

    // The account rode into the row, so re-opening the recipe still carries it.
    final written = (await recipes.listForMaster(_masterPath)).single;
    expect(
      (await recipes.draftNotesOf(written.id!)).map((n) => n.opId),
      containsAll(<String>['color_calibrate', 'crop', 'denoise', 'stretch']),
    );
    await drain(tester);
  });

  // -------------------------------------------------------------------
  // D2-03 / D3-UI-01 — the cascade delete lands on the master
  // -------------------------------------------------------------------

  testWidgets(
      'deleting a branch line that takes the open recipe lands on the master',
      (tester) async {
    final masterId = await seedMaster(name: 'Master · B', path: _masterPath);
    final root = await seedRecipe(
      [_step('denoise')],
      name: 'Master · B draft',
      masterId: masterId,
    );
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Master · B draft variant',
    );

    // The route the app is on after the operator clicks the PARENT chip: the
    // bar switches branches with `context.go(darkroomRecipeLocation(id))`, and
    // the parent is where a delete-with-children is attempted from. Opening by
    // master would open the variant, which is the newest recipe over these
    // pixels and has no children to refuse the delete.
    await pump(tester, location: '/darkroom?recipe=$root');
    expect(find.text('Master · B draft'), findsWidgets);

    await tester.tap(find.text('Delete branch'));
    await settle(tester);

    // The confirm names the whole line, because the branch it is about has a
    // branch of its own and a plain delete of it can only be refused.
    await tester.tap(
      find.widgetWithText(
        SkotiqButton,
        'Delete "Master · B draft" and its 1 branch',
      ),
    );
    await settle(tester);

    expect(await recipes.listForMaster(_masterPath), isEmpty);
    // The master is intact, so the editor offers a fresh start over it rather
    // than stranding on the id of a recipe that is gone.
    expect(find.text('Master · B has no recipe yet'), findsOneWidget);
    expect(find.text('Draft for me'), findsOneWidget);
    expect(find.text('Nothing to open in the Darkroom'), findsNothing);
    await drain(tester);
  });

  testWidgets('a missing recipe blames nothing that is still on disk',
      (tester) async {
    await pump(tester, location: '/darkroom?recipe=4242');
    expect(find.text('Nothing to open in the Darkroom'), findsOneWidget);
    // `recipes.master_id` is ON DELETE SET NULL, so a deleted master cannot
    // have taken the recipe row with it — the old sentence said it might have.
    expect(
      find.textContaining('may have been deleted along with the master'),
      findsNothing,
    );
    expect(
      find.textContaining('is still in the library'),
      findsOneWidget,
    );
  });

  // -------------------------------------------------------------------
  // D2-04 — the step stack reorders without a pointer
  // -------------------------------------------------------------------

  testWidgets('every step card offers move up and move down', (tester) async {
    final id = await seedRecipe([
      _step('crop'),
      _step('denoise'),
      _step('stretch', params: {'blackPoint': 0.0}),
    ]);
    await pump(tester, location: '/darkroom?recipe=$id');

    final semantics = tester.ensureSemantics();
    // The drag handle publishes a panel with no action, which is why a keyboard
    // and assistive tech could not move a step at all.
    expect(find.bySemanticsLabel('Move Denoise up'), findsOneWidget);
    expect(find.bySemanticsLabel('Move Crop down'), findsOneWidget);
    // At the ends the control stays, disabled, and says which end it is at —
    // the controller clamps an out-of-range destination back onto the step's
    // own index, so an enabled control there would do nothing.
    expect(
      find.bySemanticsLabel(RegExp('^Move Crop up — it is already first')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('^Move Stretch down — it is already last')),
      findsOneWidget,
    );
    semantics.dispose();
    await drain(tester);
  });

  testWidgets(
      'a move the stage rule can only refuse is disabled before the '
      'press, and says why', (tester) async {
    // [crop(linear), denoise(linear), stretch(stretched)]. The only place
    // "down" can put Denoise is past the stretch, and the only place "up" can
    // put Stretch is ahead of Denoise — the same illegal order both times, and
    // the rule decides it before anybody reaches for the control.
    final id = await seedRecipe([
      _step('crop'),
      _step('denoise'),
      _step('stretch', params: {'blackPoint': 0.0}),
    ]);
    await pump(tester, location: '/darkroom?recipe=$id');

    final semantics = tester.ensureSemantics();

    // Gated on the ends alone, both of these published themselves as live and
    // the engine refused them after the tap, every time.
    expect(find.bySemanticsLabel('Move Denoise down'), findsNothing);
    expect(find.bySemanticsLabel('Move Stretch up'), findsNothing);

    for (final name in [
      RegExp('^Move Denoise down — the stage rule refuses that order: '
          r'step 3 \(Denoise\) would be a linear-stage operation running '
          r'after step 2 \(Stretch\)'),
      RegExp('^Move Stretch up — the stage rule refuses that order: '
          r'step 3 \(Denoise\) would be a linear-stage operation running '
          r'after step 2 \(Stretch\)'),
    ]) {
      expect(find.bySemanticsLabel(name), findsOneWidget);
    }

    // The refusal is stated as DISABLED, not merely as a control that ignores
    // the press: the flag is what a screen reader announces.
    final disabled = <String>[];
    void walk(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.label.startsWith('Move Denoise down') &&
          !data.hasFlag(SemanticsFlag.isEnabled)) {
        disabled.add(data.label);
      }
      node.visitChildren((child) {
        walk(child);
        return true;
      });
    }

    walk(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    expect(disabled, hasLength(1));

    // The moves the rule permits are untouched: this closes a control, it does
    // not freeze the stack.
    expect(find.bySemanticsLabel('Move Denoise up'), findsOneWidget);
    expect(find.bySemanticsLabel('Move Crop down'), findsOneWidget);

    semantics.dispose();
    await drain(tester);
  });

  testWidgets('a stack the stage rule already refuses keeps its moves live',
      (tester) async {
    // [stretch(stretched), crop(linear), denoise(linear)] — refused however it
    // is arranged, so no move here is the one that broke it. Disabling on that
    // would blame the control for a violation it did not make AND take away
    // the moves that fix it; the engine's post-commit refusal is what covers
    // this case.
    final id = await seedRecipe([
      _step('stretch', params: {'blackPoint': 0.0}),
      _step('crop'),
      _step('denoise'),
    ]);
    await pump(tester, location: '/darkroom?recipe=$id');

    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Move Crop up'), findsOneWidget);
    expect(find.bySemanticsLabel('Move Crop down'), findsOneWidget);
    expect(find.bySemanticsLabel('Move Denoise up'), findsOneWidget);
    semantics.dispose();
    await drain(tester);
  });

  testWidgets('move up reorders the stored stack', (tester) async {
    final id = await seedRecipe([_step('crop'), _step('denoise')]);
    await pump(tester, location: '/darkroom?recipe=$id');

    await tester.tap(find.byTooltip('Move Denoise up'));
    // Past the save debounce, not just the render one: the row is what the
    // assertion reads.
    await settle(tester);
    await drain(tester);

    final stored = await recipes.getById(id);
    final steps = jsonDecode(stored!.stepsJson) as List;
    expect(
      [for (final step in steps) (step as Map)['opId']],
      ['denoise', 'crop'],
    );
  });

  // -------------------------------------------------------------------
  // D2-05 / D2-06 — the parameter controls
  // -------------------------------------------------------------------

  testWidgets(
      'a slider-ranged parameter carries a typed field for its working region',
      (tester) async {
    final id = await seedRecipe([
      _step('stretch', params: {'blackPoint': 529.7, 'd': 1.938}),
    ]);
    await pump(tester, location: '/darkroom?recipe=$id');
    await tester.tap(find.text('Parameters'));
    await settle(tester);

    // The slider still spans the registry's own range; the field is how the
    // region between two pixels of its travel is reached. One click a finger's
    // width along a 0…100 track moved the autopilot's 1.938 to 18.947.
    expect(find.byType(SkotiqSlider), findsOneWidget);
    final exact = find.widgetWithText(SkotiqTextField, '1.938');
    expect(exact, findsOneWidget);

    await tester.enterText(exact, '2.4');
    await settle(tester);
    await drain(tester);

    final stored = await recipes.getById(id);
    final steps = jsonDecode(stored!.stepsJson) as List;
    expect((steps.first as Map)['params']['d'], closeTo(2.4, 1e-9));
  });

  testWidgets('parameters are labelled with the registry\'s display name',
      (tester) async {
    final id = await seedRecipe([
      _step('stretch', params: {'blackPoint': 529.7, 'd': 1.938}),
    ]);
    await pump(tester, location: '/darkroom?recipe=$id');
    await tester.tap(find.text('Parameters'));
    await settle(tester);

    expect(find.text('Stretch intensity'), findsOneWidget);
    // The unit rides in the name, because the +/-1e12 bounds are the engine's
    // accepted range and not an ADU range any master occupies.
    expect(find.text('Black point (ADU)'), findsOneWidget);
    expect(find.text('d'), findsNothing);
    expect(find.text('blackPoint'), findsNothing);
    // The name is printed ONCE. The wide-ranged parameter's field sits under
    // that title and under the registry's summary of it, so it carries the
    // half neither of them states — the accepted bounds — rather than the
    // whole label a third time.
    expect(
        find.textContaining('Black point (ADU) (no practical'), findsNothing);
    expect(
      find.text('no practical limit; the engine refuses past ±1.00e+12'),
      findsOneWidget,
    );
    await drain(tester);
  });

  // -------------------------------------------------------------------
  // D2-07 — an available export option states its own reason
  // -------------------------------------------------------------------

  testWidgets('an enabled export option publishes its rationale, not a hover',
      (tester) async {
    final id = await seedRecipe([
      _step('stretch', params: {'blackPoint': 0.0}),
    ]);
    await pump(tester, location: '/darkroom?recipe=$id');
    await tester.tap(find.text('Export…'));
    await settle(tester);

    final semantics = tester.ensureSemantics();
    // Before: `button: FITS`, and the sentence lived only in a tooltip — which
    // is nothing at all from a keyboard, a screen reader or a touch screen.
    final fits = find.bySemanticsLabel(RegExp('^FITS — '));
    expect(fits, findsOneWidget);
    expect(
      tester.getSemantics(fits).label,
      contains('own F32 samples'),
    );
    expect(tester.getSemantics(fits).flagsCollection.isButton, isTrue);
    // And the chosen format says what it writes on screen, with no pointer.
    expect(
      find.textContaining('FITS: The engine\'s own F32 samples'),
      findsOneWidget,
    );
    semantics.dispose();
    await drain(tester);
  });

  // -------------------------------------------------------------------
  // D2-10 — the night's other masters
  // -------------------------------------------------------------------

  testWidgets('the branch bar names the night\'s other drafts with links',
      (tester) async {
    // A real session row: `captured_images.session_id` is a foreign key, and
    // the fold record is the only link the night walk follows.
    final sessionId = await SessionsDao(db).startSession(name: 'D1 sim night');
    final bId = await seedMaster(
      name: 'Master · B',
      path: _masterPath,
      filter: 'B',
    );
    final lId = await seedMaster(
      name: 'Master · L',
      path: '/tmp/skotiq-test/m31_L.fits',
      filter: 'L',
    );
    final gId = await seedMaster(
      name: 'Master · G',
      path: '/tmp/skotiq-test/m31_G.fits',
      filter: 'G',
    );
    await foldFrame(bId, sessionId, 'b1');
    await foldFrame(lId, sessionId, 'l1');
    await foldFrame(gId, sessionId, 'g1');
    await seedRecipe([_step('denoise')],
        name: 'Master · B draft', masterId: bId);
    await seedRecipe(
      [_step('denoise')],
      name: 'Master · L draft',
      masterId: lId,
      path: '/tmp/skotiq-test/m31_L.fits',
    );

    await pump(tester, location: '/darkroom?master=$bId');
    await settle(tester);

    // The bar counts the night, not just this master's branches.
    expect(
        find.textContaining('This night produced 3 masters'), findsOneWidget);
    // The chip says the master once. The autopilot names a draft after the
    // master it drafted, so joining the two printed it twice on one chip.
    expect(find.textContaining('Master · L draft'), findsWidgets);
    expect(
      find.textContaining('Master · L · Master · L draft'),
      findsNothing,
    );
    // The master with no recipe is named too, and says so rather than being
    // dropped from a list the operator would then read as complete.
    expect(
      find.textContaining('Master · G — no recipe yet'),
      findsWidgets,
    );
    await drain(tester);
  });

  // -------------------------------------------------------------------
  // D2-11 — leaving the Darkroom
  // -------------------------------------------------------------------

  testWidgets('Escape leaves the Darkroom, and a Back control says so',
      (tester) async {
    final id = await seedRecipe([_step('denoise')]);
    final router = await pump(tester, location: '/darkroom?recipe=$id');

    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel(RegExp('^Back to where the Darkroom was opened')),
      findsOneWidget,
    );
    semantics.dispose();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    // Nothing to pop from a deep link, so it goes where the empty state goes:
    // the surface that lists the masters there are pixels for.
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/analytics',
    );
    await drain(tester);
  });

  // -------------------------------------------------------------------
  // The host-only gate is a screen, not a trap
  // -------------------------------------------------------------------

  testWidgets('the host-only gate carries the same way out the editor does',
      (tester) async {
    // The gate returned its own Scaffold BEFORE the shortcuts wrapper and the
    // header actions, so the ONE branch whose whole job is to send the operator
    // elsewhere was the one branch with nowhere to go: no Back in the header,
    // no action on the empty state, Escape and Alt+Left both dead, and a nav
    // rail still highlighting the screen they came from.
    final id = await seedRecipe([_step('denoise')]);
    final router = await pump(
      tester,
      location: '/darkroom?recipe=$id',
      remoteClient: true,
    );

    expect(find.text('Open the Darkroom on the imaging host'), findsOneWidget);

    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel(RegExp('^Back to where the Darkroom was opened')),
      findsOneWidget,
    );
    semantics.dispose();
    expect(
      find.byKey(const ValueKey('darkroom_remote_gate_back')),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    expect(router.routerDelegate.currentConfiguration.uri.path, '/analytics');
    await drain(tester);
  });

  testWidgets('Alt+Left leaves the host-only gate too', (tester) async {
    final id = await seedRecipe([_step('denoise')]);
    final router = await pump(
      tester,
      location: '/darkroom?recipe=$id',
      remoteClient: true,
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await settle(tester);

    expect(router.routerDelegate.currentConfiguration.uri.path, '/analytics');
    await drain(tester);
  });

  testWidgets('the gate\'s empty-state action leaves as well', (tester) async {
    final id = await seedRecipe([_step('denoise')]);
    final router = await pump(
      tester,
      location: '/darkroom?recipe=$id',
      remoteClient: true,
    );

    await tester.tap(find.byKey(const ValueKey('darkroom_remote_gate_back')));
    await settle(tester);

    expect(router.routerDelegate.currentConfiguration.uri.path, '/analytics');
    await drain(tester);
  });

  // -------------------------------------------------------------------
  // D2-13 — the delete confirmation names the children up front
  // -------------------------------------------------------------------

  testWidgets('the delete confirmation names the branches that block it',
      (tester) async {
    final root = await seedRecipe([_step('denoise')], name: 'Draft');
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, location: '/darkroom?recipe=$root');

    await tester.tap(find.text('Delete branch'));
    await settle(tester);

    // Before: the dialog's whole body was "The recipe row goes; the linear
    // master it renders does not", and the child only appeared in a refusal
    // AFTER the operator confirmed a destructive action.
    expect(
        find.textContaining('One branch diverges from this one',
            findRichText: true),
        findsOneWidget);
    expect(find.textContaining('Warmer'), findsWidgets);
    // Agreeing in number with the one branch it names, not with a plural the
    // sentence was written for.
    expect(
      find.textContaining('Warmer records the step of "Draft" it stopped '
          'matching'),
      findsOneWidget,
    );
    // And the act it offers is the one that can be carried out: the whole
    // line, named in full, rather than a "Delete" whose only outcome is the
    // engine's refusal.
    expect(
      find.textContaining('"Draft" goes only with it: 2 recipes in all, or '
          'none'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(SkotiqButton, 'Delete "Draft" and its 1 branch'),
      findsOneWidget,
    );
    expect(find.widgetWithText(SkotiqButton, 'Delete'), findsNothing);
    await drain(tester);
  });

  // -------------------------------------------------------------------
  // D2-14 — compare keeps the panels
  // -------------------------------------------------------------------

  testWidgets('compare keeps the Recipe and History panels reachable',
      (tester) async {
    final root = await seedRecipe([_step('denoise')], name: 'Draft');
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, location: '/darkroom?recipe=$root');

    await tester.tap(find.text('Compare with…'));
    await settle(tester);
    await tester.tap(find.widgetWithText(SkotiqCard, 'Warmer'));
    await settle(tester);

    // Both pictures, as before.
    expect(find.text('A · Draft'), findsOneWidget);
    expect(find.text('B · Warmer'), findsOneWidget);
    // And the two panels that say what differs, which compare used to remove
    // from the screen and from the accessibility tree entirely.
    expect(find.text('History stack'), findsOneWidget);
    expect(find.text('Denoise'), findsWidgets);
    expect(find.text('Reset to linear'), findsOneWidget);
    // The column those panels share names the branch they are showing, so the
    // stack beside two captioned panes belongs to one of them on screen —
    // once, over the surface both panels are stacked on rather than once per
    // panel.
    expect(find.text('Pane A · Draft'), findsOneWidget);
    await drain(tester);
  });

  // -------------------------------------------------------------------
  // D3DP-2 — the sidecar is readable
  // -------------------------------------------------------------------

  test('the sidecar decoder refuses a file that is not one, by name', () {
    expect(
      () => decodeDarkroomSidecar('{"kind":"something-else"}'),
      throwsA(
        isA<DarkroomRecipeFormatException>().having(
          (e) => e.message,
          'message',
          contains('"something-else"'),
        ),
      ),
    );
    expect(
      () => decodeDarkroomSidecar('{"kind":"nsrecipe"'),
      throwsA(
        isA<DarkroomRecipeFormatException>().having(
          (e) => e.message,
          'message',
          contains('not JSON'),
        ),
      ),
    );
    // A truncated sidecar whose recipe object never arrived.
    expect(
      () => decodeDarkroomSidecar('{"kind":"nsrecipe","schemaVersion":1}'),
      throwsA(
        isA<DarkroomRecipeFormatException>().having(
          (e) => e.message,
          'message',
          contains('no recipe object'),
        ),
      ),
    );
  });

  testWidgets('an imported .nsrecipe becomes a recipe over this master',
      (tester) async {
    final masterId = await seedMaster(name: 'Master · B', path: _masterPath);
    sidecarAnswer = DarkroomSidecarPick(
      path: '/tmp/skotiq-test/job_1_master_1_draft.jpg.nsrecipe',
      text: jsonEncode({
        'kind': 'nsrecipe',
        'schemaVersion': 1,
        'fingerprint': '69dbbc0189442a0d7fb286a1bb06acb8',
        'masterPath': '/tmp/skotiq-test/somewhere_else.fits',
        'recipe': {
          'baseMasterRef': '/tmp/skotiq-test/somewhere_else.fits',
          'createdBy': 'autopilot',
          'steps': [
            _step('crop'),
            _step('stretch', params: {'blackPoint': 529.7, 'd': 2.04}),
          ],
        },
      }),
    );

    await pump(tester, location: '/darkroom?master=$masterId');
    expect(find.text('Import .nsrecipe'), findsOneWidget);

    await tester.tap(find.text('Import .nsrecipe'));
    await settle(tester);

    expect(sidecarCalls, 1);
    final rows = await recipes.listForMaster(_masterPath);
    expect(rows, hasLength(1));
    expect(rows.single.name, 'Imported: job_1_master_1_draft');
    // Over THIS master's pixels, not the sidecar's own.
    expect(rows.single.baseMasterPath, _masterPath);
    final steps = jsonDecode(rows.single.stepsJson) as List;
    expect([for (final s in steps) (s as Map)['opId']], ['crop', 'stretch']);

    // The receipt says what was read and that the pixels are not the ones the
    // sidecar was written over.
    expect(
        find.textContaining('Imported from a .nsrecipe sidecar',
            findRichText: true),
        findsOneWidget);
    expect(find.textContaining('Imported 2 steps from'), findsOneWidget);
    expect(find.textContaining('somewhere_else.fits'), findsOneWidget);
    expect(find.textContaining('Every step validates'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('an imported step this build cannot run is kept and said',
      (tester) async {
    darkroom.unregisteredOps = {'wavelet_sharpen@3'};
    final masterId = await seedMaster(name: 'Master · B', path: _masterPath);
    sidecarAnswer = DarkroomSidecarPick(
      path: '/tmp/skotiq-test/future.fits.nsrecipe',
      text: jsonEncode({
        'kind': 'nsrecipe',
        'schemaVersion': 1,
        'masterPath': _masterPath,
        'recipe': {
          'steps': [
            _step('denoise'),
            _step('wavelet_sharpen', opVersion: 3),
          ],
        },
      }),
    );

    await pump(tester, location: '/darkroom?master=$masterId');
    await tester.tap(find.text('Import .nsrecipe'));
    await settle(tester);

    // Nothing was dropped on the way in: the row holds what the file held.
    final rows = await recipes.listForMaster(_masterPath);
    final steps = jsonDecode(rows.single.stepsJson) as List;
    expect(
      [for (final s in steps) (s as Map)['opId']],
      ['denoise', 'wavelet_sharpen'],
    );
    expect(find.textContaining('This build refuses 1 of them'), findsOneWidget);
    // And the card renders it the way the editor already renders an
    // unregistered operation.
    expect(
      find.textContaining('This build registers no wavelet_sharpen@3'),
      findsWidgets,
    );
    await drain(tester);
  });

  testWidgets('a dismissed import chooser writes nothing', (tester) async {
    final masterId = await seedMaster(name: 'Master · B', path: _masterPath);
    sidecarAnswer = null;

    await pump(tester, location: '/darkroom?master=$masterId');
    await tester.tap(find.text('Import .nsrecipe'));
    await settle(tester);

    expect(sidecarCalls, 1);
    expect(await recipes.listForMaster(_masterPath), isEmpty);
    // Still the offer, with its controls live again.
    expect(find.text('Master · B has no recipe yet'), findsOneWidget);
    expect(find.text('Import .nsrecipe'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('a sidecar with no steps is refused by name', (tester) async {
    final masterId = await seedMaster(name: 'Master · B', path: _masterPath);
    sidecarAnswer = const DarkroomSidecarPick(
      path: '/tmp/skotiq-test/empty.nsrecipe',
      text: '{"kind":"nsrecipe","recipe":{"steps":[]}}',
    );

    await pump(tester, location: '/darkroom?master=$masterId');
    await tester.tap(find.text('Import .nsrecipe'));
    await settle(tester);

    expect(await recipes.listForMaster(_masterPath), isEmpty);
    expect(
      find.textContaining(
        'carries a recipe with no steps',
        findRichText: true,
      ),
      findsOneWidget,
    );
    await drain(tester);
  });

  // -------------------------------------------------------------------
  // The import refusal on the OTHER entry point
  //
  // Every test above imports from the start offer, which is the layout that
  // renders `offerError`. `Import .nsrecipe` also sits in the branch bar over
  // an open recipe, and that layout rendered nothing at all: the chooser
  // closed, the recipe count did not move, and the sentence the controller had
  // already composed went nowhere. These drive the branch-bar control.
  // -------------------------------------------------------------------

  testWidgets(
      'a truncated sidecar imported from the branch bar is refused on '
      'screen', (tester) async {
    final masterId = await seedMaster(name: 'Master · B', path: _masterPath);
    final recipeId = await seedRecipe(
      [_step('denoise')],
      name: 'Master · B draft',
      masterId: masterId,
    );
    // The first 900 bytes of a real sidecar: the JSON ends mid-string.
    sidecarAnswer = const DarkroomSidecarPick(
      path: '/tmp/skotiq-test/truncated.nsrecipe',
      text: '{"kind":"nsrecipe","schemaVersion":1,"masterPath":"/tmp/night',
    );

    await pump(tester, location: '/darkroom?recipe=$recipeId');
    await settle(tester);
    // The editor is open, so this is the branch bar's control, not the offer's.
    expect(find.text('Master · B has no recipe yet'), findsNothing);
    expect(find.text('Import .nsrecipe'), findsOneWidget);

    await tester.tap(find.text('Import .nsrecipe'));
    await settle(tester);

    expect(sidecarCalls, 1);
    expect(
      await recipes.listForMaster(_masterPath),
      hasLength(1),
      reason: 'nothing was written, so the refusal is the whole outcome',
    );
    expect(find.textContaining('truncated.nsrecipe was not imported'),
        findsOneWidget);
    expect(find.textContaining('not JSON'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('the branch-bar import refusal can be dismissed', (tester) async {
    final masterId = await seedMaster(name: 'Master · B', path: _masterPath);
    final recipeId = await seedRecipe(
      [_step('denoise')],
      name: 'Master · B draft',
      masterId: masterId,
    );
    sidecarAnswer = const DarkroomSidecarPick(
      path: '/tmp/skotiq-test/empty.nsrecipe',
      text: '{"kind":"nsrecipe","recipe":{"steps":[]}}',
    );

    await pump(tester, location: '/darkroom?recipe=$recipeId');
    await settle(tester);
    await tester.tap(find.text('Import .nsrecipe'));
    await settle(tester);

    final alert = find.byKey(const ValueKey('darkroom_import_refusal'));
    expect(alert, findsOneWidget);
    expect(
      find.textContaining(
        'carries a recipe with no steps',
        findRichText: true,
      ),
      findsOneWidget,
    );

    await tester.tap(
      // SkotiqBanner's dismiss is a SkotiqIconButton (05 §6), not a
      // Material IconButton.
      find.descendant(
        of: alert,
        matching: find.byType(SkotiqIconButton),
      ),
    );
    await settle(tester);
    expect(alert, findsNothing);
    await drain(tester);
  });
  // -------------------------------------------------------------------
  // The refusal the start offer shows: what it says, and how it goes away
  // -------------------------------------------------------------------

  testWidgets('a file that is not JSON is refused with a next step', (
    tester,
  ) async {
    // The refusal ENDED on the Dart JSON reader's own fragment — "…: Unexpected
    // character." — which names nothing the operator chose and nothing they can
    // do. The missing-master error two inches away names two next steps.
    final masterId = await seedMaster(name: 'Master · B', path: _masterPath);
    sidecarAnswer = const DarkroomSidecarPick(
      path: '/tmp/skotiq-test/notjson.nsrecipe',
      text: 'this is not json at all',
    );

    await pump(tester, location: '/darkroom?master=$masterId');
    await tester.tap(find.text('Import .nsrecipe'));
    await settle(tester);

    final message = tester
        .widgetList<SkotiqBanner>(find.byType(SkotiqBanner))
        .map((banner) => banner.message)
        .whereType<String>()
        .singleWhere((text) => text.contains('was not imported'));
    expect(message, startsWith('notjson.nsrecipe was not imported:'));
    expect(message, contains('not JSON'));
    // The next step, in the file's own vocabulary.
    expect(
      message,
      contains('Export the recipe again from the Darkroom that wrote it'),
    );
    expect(message, contains('choose a different .nsrecipe file'));
    // The parser's words may FOLLOW the refusal, attributed to the reader that
    // produced them — they may never BE the refusal. Everything this screen
    // says on its own account is the part before that attribution.
    final spoken = message.split('The JSON reader stopped').first;
    expect(spoken, isNot(contains('Unexpected character')));
    expect(spoken, endsWith('choose a different .nsrecipe file. '));
    expect(message, contains('The JSON reader stopped'));
    expect(message, contains('Unexpected character'));
    await drain(tester);
  });

  testWidgets('the start offer\'s import refusal can be dismissed', (
    tester,
  ) async {
    // The identical refusal reached from the editor layout carries a close
    // affordance; on the offer it had none, so it sat on the screen until
    // another import replaced it — pushing the three start buttons down with
    // it.
    final masterId = await seedMaster(name: 'Master · B', path: _masterPath);
    sidecarAnswer = const DarkroomSidecarPick(
      path: '/tmp/skotiq-test/notjson.nsrecipe',
      text: 'this is not json at all',
    );

    await pump(tester, location: '/darkroom?master=$masterId');
    await tester.tap(find.text('Import .nsrecipe'));
    await settle(tester);

    final refusal = tester
        .widgetList<SkotiqBanner>(find.byType(SkotiqBanner))
        .singleWhere(
          (banner) => banner.message?.contains('was not imported') ?? false,
        );
    expect(
      refusal.onDismiss,
      isNotNull,
      reason: 'an alert with no onDismiss renders no close affordance at all',
    );

    final alert = find.byKey(const ValueKey('darkroom_import_refusal'));
    expect(alert, findsOneWidget);
    expect(find.textContaining('was not imported'), findsOneWidget);

    await tester.tap(
      // SkotiqBanner's dismiss is a SkotiqIconButton (05 §6), not a
      // Material IconButton.
      find.descendant(
        of: alert,
        matching: find.byType(SkotiqIconButton),
      ),
    );
    await settle(tester);

    // Gone, and the offer is the offer again: dismissal clears the one field
    // both layouts read.
    expect(alert, findsNothing);
    expect(find.textContaining('was not imported'), findsNothing);
    expect(find.text('Master · B has no recipe yet'), findsOneWidget);
    expect(find.text('Import .nsrecipe'), findsOneWidget);
    await drain(tester);
  });

  // -------------------------------------------------------------------
  // W9-B — the start offer's header is text, not a control's name
  // -------------------------------------------------------------------

  testWidgets('the start offer reads its header as text, not as Reload\'s name',
      (tester) async {
    final handle = tester.ensureSemantics();
    final masterId = await seedMaster(name: 'Master · B', path: _masterPath);
    await pump(tester, location: '/darkroom?master=$masterId');
    expect(find.text('Master · B has no recipe yet'), findsOneWidget);

    // The header action is a bare fragment with a tap on it and the header's
    // words are fragments with none, so in THIS layout — whose body publishes
    // its own boundary — the two merged and the whole header reached AT-SPI as
    // one button named "Darkroom / No recipe yet / Reload". The editor layout
    // escaped it only because its body has actions of its own to be
    // incompatible with, which is why one state of one screen read correctly
    // and the other did not.
    //
    // The subtitle is gone (04-shell §4 has no slot for one), so the header's
    // words are now the page TITLE — which makes the merge worse if it comes
    // back, not better: the screen's name would only be readable as part of a
    // control's.
    final reload = find.widgetWithText(SkotiqButton, 'Reload');
    final node = tester.getSemantics(reload);
    final data = node.getSemanticsData();
    expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(data.label, contains('Reload'));
    expect(data.label, isNot(contains('Darkroom')));
    expect(node.rect.size, tester.getSize(reload));

    // The header's own words are still reachable, on a node with no role.
    final spoken = <String>[];
    void visit(SemanticsNode node) {
      if (node.isMergedIntoParent) return;
      final data = node.getSemanticsData();
      // The page TITLE exactly, not any label containing the word: the Back
      // control's own name ("Back to where the Darkroom was opened from") is a
      // button, and legitimately so.
      if (data.label == 'Darkroom') {
        spoken.add(data.label);
        expect(data.hasFlag(SemanticsFlag.isButton), isFalse);
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    expect(
      spoken,
      isNotEmpty,
      reason: 'the page title must be readable on its own node, not only '
          'inside a button\'s name',
    );
    handle.dispose();
    await drain(tester);
  });
}
