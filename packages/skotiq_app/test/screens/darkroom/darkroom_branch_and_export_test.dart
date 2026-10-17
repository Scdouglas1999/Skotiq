// Widget tests for the Darkroom's branch bar, A/B compare and export sheet.
//
// These assert what a reader of the code cannot see:
//
//  * the branch bar names who wrote each branch and refuses a parent delete out
//    loud, with the branches that blocked it on screen;
//  * an A/B compare hands BOTH viewers the same TransformationController, which
//    is what keeps a drag-pan in sync — a callback-based sync would come apart
//    on the first drag, because a drag reaches no callback;
//  * blink keeps both panes mounted, so a swap is a buffer change and not a
//    remount with a blank frame in the middle of it;
//  * the export sheet shows the engine's raster refusal as readable text, not
//    just a greyed chip, and one switch turns it into a choice;
//  * a FITS export names its `.nsrecipe` sidecar on the wire rather than hoping
//    the engine derives one;
//  * what those controls publish to assistive tech — the refusal's reason, the
//    export sheet's answer to Escape, its phone presentation, and a
//    hold-to-compare that a keyboard can work.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_branch_controller.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_controller.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'package:go_router/go_router.dart';

import '../../harness/mock_backend.dart';
import '../../harness/mock_database.dart';
import '../../harness/pump_app_screen.dart';

/// A Darkroom seam whose every reply the test writes.
class _ScriptedDarkroom implements DarkroomSeam {
  /// Every `renderExport` args map, in call order.
  final List<Map<String, dynamic>> exportArgs = [];

  /// Every `renderExport` recipe payload, in the same order.
  final List<String> exportRecipes = [];

  /// Every `cancel` args map, in call order.
  final List<Map<String, dynamic>> cancelArgs = [];

  /// Held open to keep an export inside the engine.
  Completer<void>? holdExport;

  /// Thrown out of the next `renderExport` when set.
  Object? exportFailure;

  /// Thrown out of every `renderPreview` while set, the way a master that is no
  /// longer on disk fails every render rather than the first.
  Object? previewFailure;

  /// The engine's whole-recipe refusal while set, blamed on [invalidStep].
  ///
  /// The engine validates a recipe as a whole before it touches a pixel, so a
  /// refusal here is what every surface that replays the stack — the render,
  /// and the export's replaying stages — comes back with.
  String? validationError;

  /// Which step index [validationError] is about.
  int invalidStep = 0;

  @override
  Future<Map<String, dynamic>> validate({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    final steps =
        (jsonDecode(recipeJson) as Map<String, dynamic>)['steps'] as List;
    final error = validationError;
    return {
      'ok': error == null,
      'error': error,
      'steps': [
        for (var i = 0; i < steps.length; i++)
          {
            'index': i,
            'registered': true,
            'valid': error == null || i != invalidStep,
            if (error != null && i == invalidStep) 'error': error,
          },
      ],
    };
  }

  @override
  Future<DarkroomRenderedPreview> renderPreview({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    final failure = previewFailure;
    if (failure != null) throw failure;
    final steps =
        (jsonDecode(recipeJson) as Map<String, dynamic>)['steps'] as List;
    return DarkroomRenderedPreview(
      width: 4,
      height: 4,
      isColor: false,
      rgba: Uint8List(4 * 4 * 4),
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
    exportArgs.add(args);
    exportRecipes.add(recipeJson);
    final hold = holdExport;
    if (hold != null) {
      holdExport = null;
      await hold.future;
    }
    final failure = exportFailure;
    if (failure != null) {
      exportFailure = null;
      throw failure;
    }
    final outputs = args['outputs'] as List;
    final first = outputs.first as Map<String, dynamic>;
    return {
      'stage': args['stage'],
      'outputs': [
        {
          'format': first['format'],
          'path': first['path'],
          'bytes': 4096,
          'width': 4,
          'height': 4,
          'clampedSamples': 0,
        },
      ],
      'sidecarPath': args['sidecarPath'],
      'sidecarSkippedReason': null,
      'sourceDomain': 'linear',
      'screenTransfer': null,
      'recipeFingerprint': 'abc123',
    };
  }

  @override
  Future<Map<String, dynamic>> registry(Map<String, dynamic> args) async {
    return {
      'schemaVersion': 1,
      'ops': [
        {
          'id': 'background_extract',
          'version': 1,
          'stage': 'linear',
          'summary': 'Fits and subtracts a smooth background model.',
          'params': const <dynamic>[],
        },
        {
          'id': 'stretch',
          'version': 1,
          'stage': 'stretched',
          'summary': 'Generalised hyperbolic stretch.',
          'params': const <dynamic>[],
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> cancel(Map<String, dynamic> args) async {
    cancelArgs.add(args);
    return {'renderId': args['renderId'], 'running': true};
  }
}

DawnPhotometryResolver _emptyPhotometry() {
  return DawnPhotometryResolver(
    coneSearch: (center, radiusDegrees, {maxMagnitude}) async => const [],
  );
}

const String _masterPath = '/tmp/skotiq-test/m31_L.fits';

Map<String, dynamic> _step(String opId, {bool enabled = true}) => {
      'opId': opId,
      'opVersion': 1,
      'params': <String, dynamic>{},
      'enabled': enabled,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the variant name a duplicate suggests', () {
    test('is the plain one while no sibling wears it', () {
      expect(
        darkroomVariantNameSuggestion('Draft', const ['Draft']),
        'Draft variant',
      );
    });

    test('numbers past every sibling that already wears one', () {
      expect(
        darkroomVariantNameSuggestion(
          'Draft',
          const ['Draft', 'Draft variant'],
        ),
        'Draft variant 2',
      );
      expect(
        darkroomVariantNameSuggestion(
          'Draft',
          const ['Draft', 'Draft variant', 'Draft variant 2'],
        ),
        'Draft variant 3',
      );
      // A gap is filled rather than stepped over: the number says "not that
      // one", not "how many there have ever been".
      expect(
        darkroomVariantNameSuggestion(
          'Draft',
          const ['Draft variant', 'Draft variant 3'],
        ),
        'Draft variant 2',
      );
    });

    test('reads case and surrounding space the way the bar does', () {
      expect(
        darkroomVariantNameSuggestion('Draft', const ['  draft VARIANT ']),
        'Draft variant 2',
      );
    });
  });

  late _ScriptedDarkroom darkroom;
  late SkotiqDatabase db;
  late RecipesDao recipes;
  late List<Map<String, Object?>> pickerCalls;
  String? pickerAnswer;

  /// Held open to keep the save chooser up, the way a real one stays up until
  /// the operator answers it.
  Completer<String?>? pickerHold;

  /// Thrown out of the reveal/share hand-off when set — the shape a platform
  /// whose share sheet refuses takes AFTER the file is already on disk.
  Object? revealFailure;

  /// How many times the written file was handed to the OS.
  late int revealCalls;

  setUp(() {
    darkroom = _ScriptedDarkroom();
    db = mockDatabase();
    recipes = RecipesDao(db);
    pickerCalls = [];
    pickerAnswer = '/tmp/skotiq-test/out.fits';
    pickerHold = null;
    revealFailure = null;
    revealCalls = 0;
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedRecipe(
    List<Map<String, dynamic>> steps, {
    String name = 'Draft',
    RecipeAuthor by = RecipeAuthor.autopilot,
  }) {
    return recipes.create(
      baseMasterPath: _masterPath,
      name: name,
      stepsJson: jsonEncode(steps),
      createdBy: by,
    );
  }

  /// Pump the Darkroom behind a real router.
  ///
  /// Not `pumpAppScreen`: the branch bar switches branches with `context.go`,
  /// so a tree with no router would make every one of those controls throw in
  /// the test while working in the app — the opposite of what a widget test is
  /// for. The route shape mirrors `app_router.dart`'s own `/darkroom`.
  Future<GoRouter> pump(
    WidgetTester tester,
    int recipeId, {
    Size size = const Size(1400, 900),

    /// Where the router starts, when the test needs the master-scoped entry
    /// point rather than `?recipe=`. Every in-app route into the Darkroom uses
    /// `?master=`, and that is the route the delete fallback lands back on.
    String? location,
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
        darkroomSavePickerProvider.overrideWithValue(({
          required String suggestedName,
          required List<String> allowedExtensions,
          required String confirmButtonText,
        }) async {
          pickerCalls.add({
            'suggestedName': suggestedName,
            'allowedExtensions': allowedExtensions,
            'confirmButtonText': confirmButtonText,
          });
          final hold = pickerHold;
          if (hold != null) {
            pickerHold = null;
            return hold.future;
          }
          return pickerAnswer;
        }),
        darkroomFileRevealerProvider.overrideWithValue((
          BuildContext context,
          String filePath, {
          String subject = '',
        }) async {
          revealCalls += 1;
          final failure = revealFailure;
          if (failure != null) throw failure;
        }),
      ],
    );
    addTearDown(container.dispose);

    final router = GoRouter(
      initialLocation: location ?? '/darkroom?recipe=$recipeId',
      routes: [
        GoRoute(
          path: '/darkroom',
          builder: (context, state) {
            // Both query parameters, exactly as `app_router.dart` reads them:
            // the delete fallback goes to `?master=`, and a route that could
            // not express that would make this test pass on a shape the app
            // never takes.
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
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    return router;
  }

  /// Pump enough frames for a dialog route and one round of controller work to
  /// land. Deliberately NOT `pumpAndSettle`: the editor keeps an indeterminate
  /// progress animation up while a render is in the engine, so a settle never
  /// converges.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// Pump past every timer the screen arms so teardown finds none pending.
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
  }

  // ---------------------------------------------------------------------
  // Branch bar
  // ---------------------------------------------------------------------

  testWidgets(
      'deleting a master\'s only branch leaves the offer, not the deleted '
      'recipe', (tester) async {
    final masterId = await IntegratedMastersDao(db).insertMaster(
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
    final only = await recipes.create(
      masterId: masterId,
      baseMasterPath: _masterPath,
      name: 'Only',
      stepsJson: jsonEncode([_step('background_extract')]),
      createdBy: RecipeAuthor.autopilot,
    );

    // The master-scoped route, which is what every in-app entry point opens.
    await pump(tester, only, location: '/darkroom?master=$masterId');
    expect(find.text('Only'), findsWidgets);

    await tester.tap(find.text('Delete branch'));
    await settle(tester);
    await tester.tap(find.widgetWithText(SkotiqButton, 'Delete'));
    await settle(tester);

    // The delete's fallback is the location the screen is ALREADY on, so
    // nothing about the route changes and the same scope hands back the same
    // controller. Without an explicit invalidate the editor kept rendering the
    // deleted recipe with every action live.
    expect(await recipes.listForMaster(_masterPath), isEmpty);
    expect(find.text('M31 B has no recipe yet'), findsOneWidget);
    expect(find.text('Draft for me'), findsOneWidget);
    expect(find.text('Delete branch'), findsNothing);
    expect(find.text('Export…'), findsNothing);
    // And the header does not name the recipe that no longer exists.
    expect(find.text('Only'), findsNothing);
    await drain(tester);
  });

  testWidgets('every branch chip publishes exactly one named node', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);

    final handle = tester.ensureSemantics();
    // The tappable chip carries its own complete node — label, button role,
    // enabled flag, selected state. A second annotation over it published a
    // nameless node with NO enabled flag wrapping the real one, which the
    // AT-SPI bridge reported as a disabled, unnamed button.
    expect(find.bySemanticsLabel('Warmer'), findsOneWidget);
    // The open recipe's chip has no tap to offer, so it says what it is.
    expect(
      find.bySemanticsLabel('Draft — the recipe this editor is showing'),
      findsOneWidget,
    );

    final nameless = <int>[];
    void walk(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.hasFlag(SemanticsFlag.isButton) && data.label.isEmpty) {
        nameless.add(node.id);
      }
      node.visitChildren((child) {
        walk(child);
        return true;
      });
    }

    walk(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    expect(nameless, isEmpty, reason: 'a button with no name names nothing');
    handle.dispose();
    await drain(tester);
  });

  testWidgets('the bar names every branch and who wrote it', (tester) async {
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);

    expect(find.widgetWithText(SkotiqChip, 'Draft'), findsOneWidget);
    expect(find.widgetWithText(SkotiqChip, 'Warmer'), findsOneWidget);
    // The autopilot's draft and the operator's variant carry different marks.
    expect(find.byIcon(SkotiqIcons.sparkle), findsWidgets);
    expect(find.byIcon(SkotiqIcons.user), findsWidgets);
    expect(find.textContaining('Lineage:'), findsNothing);
    await drain(tester);
  });

  testWidgets('a branch states the lineage it came from', (tester) async {
    final root = await seedRecipe([_step('background_extract')]);
    final variant = await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, variant);

    expect(
      find.textContaining('Lineage: Draft → Warmer (from step 1)'),
      findsOneWidget,
    );
    await drain(tester);
  });

  testWidgets('a chip strip a phone clips can still be reached', (
    tester,
  ) async {
    // 430x900 is the phone reflow the UX pass measured. At that width the
    // branch row runs past the viewport and the chips behind the edge were
    // unreachable: the row is a bare horizontal SingleChildScrollView, so it
    // showed no scrollbar, a vertical wheel over it did nothing (Flutter sends
    // wheel deltas along the scrollable's own axis), and a mouse drag was
    // refused because `dragDevices` excludes the mouse on every platform. The
    // chips were in the semantics tree and out of reach — the worst of both.
    final root = await seedRecipe([_step('background_extract')]);
    for (final name in ['Warmer', 'Cooler', 'Sharper', 'Softer']) {
      await recipes.branchFrom(
        parentRecipeId: root,
        divergenceIndex: 1,
        name: name,
      );
    }
    await pump(tester, root, size: const Size(430, 900));

    // The precondition: the strip really does overflow at this width.
    final last = find.widgetWithText(SkotiqChip, 'Softer');
    expect(last, findsOneWidget);
    expect(
      tester.getRect(last).right,
      greaterThan(430.0),
      reason: 'the case only exists while the last chip is off-screen',
    );

    final strip = find.byKey(kDarkroomBranchStripKey);
    expect(strip, findsOneWidget);

    // A scrollbar: something on screen that says there is more, and a thumb a
    // mouse can drag.
    expect(
      find.descendant(of: strip, matching: find.byType(Scrollbar)),
      findsOneWidget,
    );

    // A mouse drag over the chips scrolls them, the way a finger does.
    final scrollable = find.descendant(
      of: strip,
      matching: find.byType(SingleChildScrollView),
    );
    expect(
      ScrollConfiguration.of(
        tester.element(scrollable),
      ).dragDevices.contains(PointerDeviceKind.mouse),
      isTrue,
      reason: 'a desktop pointer must be able to drag the strip',
    );

    // And the wheel, which is what a desktop hand reaches for first.
    final before = tester.getRect(last).left;
    final position = tester.getCenter(strip);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    tester.binding.handlePointerEvent(pointer.hover(position));
    tester.binding.handlePointerEvent(
      pointer.scroll(const Offset(0, 120)),
    );
    await tester.pump();
    expect(
      tester.getRect(last).left,
      lessThan(before - 50),
      reason: 'a vertical wheel over a horizontal strip must move it',
    );
    await drain(tester);
  });

  testWidgets('duplicate as variant writes a branch of the open recipe', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await pump(tester, root);

    await tester.tap(find.text('Duplicate as variant'));
    await settle(tester);

    expect(find.text('Duplicate as variant'), findsWidgets);
    await tester.tap(find.text('Create variant'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    final rows = await recipes.listForMaster(_masterPath);
    expect(rows, hasLength(2));
    final variant = rows.firstWhere((r) => r.id != root);
    expect(variant.parentRecipeId, root);
    expect(variant.divergenceIndex, 1);
    expect(variant.createdBy, RecipeAuthor.user);
    await drain(tester);
  });

  testWidgets('a second variant is suggested a name the first does not wear', (
    tester,
  ) async {
    // Accepting the suggestion twice made two chips labelled "Draft variant",
    // two identical rows in the compare picker, and a refusal that named the
    // same recipe twice — nothing on the bar could tell them apart.
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Draft variant',
    );
    await pump(tester, root);

    await tester.tap(find.text('Duplicate as variant'));
    await settle(tester);

    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      'Draft variant 2',
    );

    // And it is still a suggestion: the field takes any name the operator
    // types over it.
    await tester.enterText(find.byType(EditableText), 'Cooler');
    await settle(tester);
    await tester.tap(find.text('Create variant'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    final names =
        (await recipes.listForMaster(_masterPath)).map((r) => r.name).toList();
    expect(names, containsAll(<String>['Draft', 'Draft variant', 'Cooler']));
    await drain(tester);
  });

  testWidgets('a compare option is a row control, not centred text', (
    tester,
  ) async {
    // The picker's options were label text inside a hairline outline, in a
    // dialog whose only element painted as a control was Cancel: a click at the
    // row's visual centre of gravity did nothing unless it landed on the text.
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);

    await tester.tap(find.text('Compare with…'));
    await settle(tester);

    final option = find.widgetWithText(SkotiqCard, 'Warmer');
    expect(option, findsOneWidget);
    expect(tester.widget<SkotiqCard>(option).onTap, isNotNull);
    // The affordance that says the row leads somewhere.
    expect(
      find.descendant(
        of: option,
        matching: find.byIcon(SkotiqIcons.chevronRight),
      ),
      findsOneWidget,
    );

    // A press on the row's own surface — off the label, where the eye aims —
    // chooses that branch.
    final box = tester.getRect(option);
    await tester.tapAt(Offset(box.right - 24, box.center.dy));
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.text('Stop comparing'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('deleting a parent explains itself with the branches named', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);

    await tester.tap(find.text('Delete branch'));
    await settle(tester);

    // The branch that blocks a plain delete is NAMED in the confirm, and the
    // only destructive button is the act that can actually be carried out. The
    // dialog used to quote the child count, state that the delete would be
    // refused, and still put "Delete" under it — one guaranteed failure before
    // the operator was offered the escalation.
    expect(
        find.textContaining('One branch diverges from this one',
            findRichText: true),
        findsOneWidget);
    expect(find.textContaining('Warmer'), findsWidgets);
    expect(
      find.widgetWithText(SkotiqButton, 'Delete "Draft" and its 1 branch'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(SkotiqButton, 'Delete'),
      findsNothing,
      reason: 'a button whose only outcome is a refusal is not a choice',
    );

    // Backing out leaves the family exactly as it was.
    await tester.tap(find.widgetWithText(SkotiqButton, 'Keep it'));
    await settle(tester);
    expect(await recipes.listForMaster(_masterPath), hasLength(2));
    await drain(tester);
  });

  // Escape and a tap on the barrier are how every other modal in this app is
  // backed out of — the shared `ConfirmDialog`, the export sheet on this very
  // screen — and these two answered neither, so the only way out of a delete
  // confirm was to aim at one of its three buttons.
  testWidgets('Escape backs out of the delete confirm and keeps the branch', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await pump(tester, root);

    await tester.tap(find.text('Delete branch'));
    await settle(tester);
    expect(find.text('Delete "Draft"?'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    // The dialog is gone and the key took the SAFE path: Escape is "Keep it",
    // never the destructive button.
    expect(find.text('Delete "Draft"?'), findsNothing);
    expect(await recipes.listForMaster(_masterPath), hasLength(1));
    // And it was spent on the dialog, not on the screen behind it — the shell
    // binds Escape to leaving the Darkroom.
    expect(find.text('Delete branch'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('a tap outside the delete confirm keeps the branch', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await pump(tester, root);

    await tester.tap(find.text('Delete branch'));
    await settle(tester);
    expect(find.text('Delete "Draft"?'), findsOneWidget);

    // The corner of the window, which is barrier and nothing else — the dialog
    // is 480 wide and centred.
    await tester.tapAt(const Offset(12, 12));
    await settle(tester);

    expect(find.text('Delete "Draft"?'), findsNothing);
    expect(await recipes.listForMaster(_masterPath), hasLength(1));
    await drain(tester);
  });

  testWidgets('Escape backs out of the rename dialog and keeps the label', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await pump(tester, root);

    await tester.tap(find.text('Rename'));
    await settle(tester);
    expect(find.text('Rename this branch'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    expect(find.text('Rename this branch'), findsNothing);
    expect((await recipes.getById(root))!.name, 'Draft');
    expect(find.text('Rename'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('the confirm\'s own escalation deletes the whole line', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);

    await tester.tap(find.text('Delete branch'));
    await settle(tester);
    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Delete "Draft" and its 1 branch'),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    // Both rows, in one step, with no refusal in between.
    expect(await recipes.listForMaster(_masterPath), isEmpty);
    expect(
        find.textContaining('That branch has branches of its own',
            findRichText: true),
        findsNothing);
    await drain(tester);
  });

  testWidgets('a delete the engine refuses still offers the whole line', (
    tester,
  ) async {
    // The refusal path survives the confirm's own escalation: a branch can gain
    // a child between the confirm being drawn and the delete being asked for,
    // and the engine — not this screen — is what refuses. Driven through the
    // controller, which is the seam that state arrives on.
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    final router = await pump(tester, root);
    final context = tester.element(find.byType(DarkroomScreen));
    final container = ProviderScope.containerOf(context);
    await container
        .read(
          darkroomBranchControllerProvider(
            DarkroomBranchScope(masterPath: _masterPath, recipeId: root),
          ).notifier,
        )
        .deleteBranch(root);
    await settle(tester);

    expect(
        find.textContaining('That branch has branches of its own',
            findRichText: true),
        findsOneWidget);
    expect(
      find.textContaining('cannot be deleted while 1 branch'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Delete "Draft" and its 1 branch'),
      findsOneWidget,
    );
    expect(await recipes.listForMaster(_masterPath), hasLength(2));
    expect(router.routerDelegate.currentConfiguration.uri.toString(),
        '/darkroom?recipe=$root');
    await drain(tester);
  });

  // ---------------------------------------------------------------------
  // A/B compare
  // ---------------------------------------------------------------------

  Future<void> enterCompare(WidgetTester tester) async {
    await tester.tap(find.text('Compare with…'));
    await settle(tester);
    // The whole row is the control, so the tap lands where the eye aims: the
    // middle of the card rather than the label inside it.
    await tester.tap(find.widgetWithText(SkotiqCard, 'Warmer'));
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// Let the panes' pixel decodes finish.
  ///
  /// `decodeImageFromPixels` answers from the engine, which the fake clock
  /// inside `testWidgets` never reaches — so without real time the surfaces
  /// stay on their first-frame spinner and never build the viewer that carries
  /// the transform.
  Future<void> decodeFrames(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }

  testWidgets('both compare panes share ONE transform controller', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);
    await enterCompare(tester);
    await decodeFrames(tester);

    final viewers = tester
        .widgetList<InteractiveViewer>(find.byType(InteractiveViewer))
        .toList();
    expect(viewers, hasLength(2));
    final shared = viewers.first.transformationController;
    expect(shared, isNotNull);
    // Identity, not equality: the sync IS the shared controller. A drag-pan or
    // a pinch reaches no callback, so two controllers kept in step by one would
    // diverge on the first drag.
    expect(identical(viewers[1].transformationController, shared), isTrue);

    // Driving it from outside moves both panes, because both read it.
    final before = shared!.value.clone();
    shared.value = Matrix4.identity()..scaleByDouble(2.0, 2.0, 1.0, 1.0);
    await tester.pump();
    expect(shared.value, isNot(before));
    for (final viewer in tester.widgetList<InteractiveViewer>(
      find.byType(InteractiveViewer),
    )) {
      expect(identical(viewer.transformationController, shared), isTrue);
    }
    await drain(tester);
  });

  testWidgets('blink swaps between two mounted panes, never remounting one', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);
    await enterCompare(tester);

    await tester.tap(find.widgetWithText(SkotiqChip, 'Blink'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    // BOTH panes stay mounted and one is painted. Building only the showing
    // side tore the other down on every tick, so each swap re-mounted a pane
    // with no decoded frame and the comparator showed a blank between the two
    // frames the mode exists to compare.
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 0);
    expect(find.text('Showing A'), findsOneWidget);
    // `skipOffstage: false` on purpose: the pane that is not showing is
    // deliberately not painted, and this is the assertion that it is
    // nevertheless still there.
    final before = find
        .byKey(kDarkroomPreviewSurfaceKey, skipOffstage: false)
        .evaluate()
        .toList();
    expect(before, hasLength(2));
    // Exactly one of them is on screen.
    expect(find.byKey(kDarkroomPreviewSurfaceKey), findsOneWidget);

    await tester.pump(kDarkroomBlinkInterval);
    expect(find.text('Showing B'), findsOneWidget);
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack)).index, 1);

    // Element identity, not widget count: the same two elements survive the
    // swap, so neither pane's decoded frame is thrown away and re-decoded —
    // which is what put a blank frame between every A and B.
    final after = find
        .byKey(kDarkroomPreviewSurfaceKey, skipOffstage: false)
        .evaluate()
        .toList();
    expect(after, hasLength(2));
    expect(identical(after[0], before[0]), isTrue);
    expect(identical(after[1], before[1]), isTrue);

    // Pausing stops the alternation rather than merely hiding the label.
    await tester.tap(find.text('Pause blink'));
    await tester.pump();
    final showing = find.text('Showing B').evaluate().isNotEmpty;
    await tester.pump(kDarkroomBlinkInterval * 3);
    expect(find.text(showing ? 'Showing B' : 'Showing A'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('hold-to-compare pins the other recipe up while held', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);
    await enterCompare(tester);
    await tester.tap(find.widgetWithText(SkotiqChip, 'Blink'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    final hold = find.text('Hold to see Warmer');
    expect(hold, findsOneWidget);
    final gesture = await tester.startGesture(tester.getCenter(hold));
    await tester.pump();
    expect(find.text('Showing B'), findsOneWidget);
    // The blink timer cannot take the B side away while it is held.
    await tester.pump(kDarkroomBlinkInterval * 2);
    expect(find.text('Showing B'), findsOneWidget);

    await gesture.up();
    await tester.pump();
    await drain(tester);
  });

  testWidgets('a phone stacks the two panes instead of shrinking them', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root, size: const Size(390, 844));
    await enterCompare(tester);

    final viewers = find.byKey(kDarkroomPreviewSurfaceKey);
    expect(viewers, findsNWidgets(2));
    final first = tester.getRect(viewers.at(0));
    final second = tester.getRect(viewers.at(1));
    // Stacked, not side by side: two 180-pixel-wide renders compare nothing.
    expect(second.top, greaterThanOrEqualTo(first.bottom - 1));
    expect(first.width, closeTo(second.width, 1));
    await drain(tester);
  });

  // ---------------------------------------------------------------------
  // Export sheet
  // ---------------------------------------------------------------------

  Future<void> openExport(WidgetTester tester) async {
    await tester.tap(find.text('Export…'));
    await settle(tester);
  }

  testWidgets('a still-linear stage says WHY the rasters are unavailable', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await pump(tester, root);
    await openExport(tester);

    expect(
      find.textContaining(
        'PNG, JPEG and TIFF are unavailable for this stage',
        findRichText: true,
      ),
      findsOneWidget,
    );
    // The reason is READ, not hovered: a tooltip says nothing on a touch
    // screen, and this refusal is the whole point of the stage picker.
    expect(
      find.textContaining('still linear ADU and has no display mapping'),
      findsOneWidget,
    );
    final png = tester.widget<SkotiqChip>(
      find.widgetWithText(SkotiqChip, 'PNG'),
    );
    expect(png.enabled, isFalse);
    final fits = tester.widget<SkotiqChip>(
      find.widgetWithText(SkotiqChip, 'FITS'),
    );
    expect(fits.enabled, isTrue);

    await tester.tap(find.byType(SkotiqSwitch).last);
    await settle(tester);
    expect(
      tester.widget<SkotiqChip>(find.widgetWithText(SkotiqChip, 'PNG')).enabled,
      isTrue,
    );

    Navigator.of(tester.element(find.text('Export'))).pop();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('a stack that ends stretched offers the rasters directly', (
    tester,
  ) async {
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    await pump(tester, root);
    await openExport(tester);

    expect(
      find.textContaining(
        'PNG, JPEG and TIFF are unavailable for this stage',
        findRichText: true,
      ),
      findsNothing,
    );
    expect(
      tester
          .widget<SkotiqChip>(find.widgetWithText(SkotiqChip, 'JPEG'))
          .enabled,
      isTrue,
    );

    Navigator.of(tester.element(find.text('Export'))).pop();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('a FITS export names its sidecar and its stage on the wire', (
    tester,
  ) async {
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    await pump(tester, root);
    await openExport(tester);

    await tester.tap(find.text('Export'));
    await settle(tester);

    expect(pickerCalls, hasLength(1));
    expect(pickerCalls.single['allowedExtensions'], contains('fits'));
    expect(darkroom.exportArgs, hasLength(1));
    final args = darkroom.exportArgs.single;
    expect(args['masterPath'], _masterPath);
    expect((args['stage'] as Map)['kind'], 'final');
    expect(args['writeSidecar'], isTrue);
    expect(args['sidecarPath'], '/tmp/skotiq-test/out.fits.nsrecipe');
    expect(args['screenTransfer'], isFalse);
    expect((args['outputs'] as List).single, {
      'format': 'fits',
      'path': '/tmp/skotiq-test/out.fits',
    });
    expect((args['renderId'] as String), startsWith('darkroom-export-$root-'));

    // The reply's own numbers are reported back, sidecar included.
    expect(find.textContaining('Written', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('/tmp/skotiq-test/out.fits.nsrecipe'),
      findsOneWidget,
    );
    await drain(tester);
  });

  testWidgets('an after-step export carries the index it stops at', (
    tester,
  ) async {
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    await pump(tester, root);
    await openExport(tester);

    await tester.tap(find.widgetWithText(SkotiqChip, 'After a step'));
    await settle(tester);
    await tester.tap(find.text('Export'));
    await settle(tester);

    final stage = darkroom.exportArgs.single['stage'] as Map;
    expect(stage['kind'], 'afterStep');
    expect(stage['index'], 1);
    await drain(tester);
  });

  testWidgets('a cancelled export says so and reports no file', (tester) async {
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    await pump(tester, root);
    await openExport(tester);

    final held = Completer<void>();
    darkroom.holdExport = held;
    darkroom.exportFailure = const DarkroomCancelledOutcome(
      id: 'darkroom-export',
      phase: 'render',
      payload: {'kind': 'cancelled'},
    );
    await tester.tap(find.text('Export'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(find.text('Stopping…'), findsOneWidget);
    expect(darkroom.cancelArgs.last['op'], 'cancel');

    held.complete();
    await settle(tester);
    expect(
      find.textContaining('stopped during render. No file was written.'),
      findsOneWidget,
    );
    expect(find.textContaining('Written', findRichText: true), findsNothing);
    await drain(tester);
  });

  // The engine's own sentence, copied from the release bundle refusing a
  // `whitePoint` set below the step's `blackPoint`.
  const refusal = 'step 2 (stretch@1) has invalid parameters: stretch@1: '
      "parameter 'whitePoint' = 100 is outside (529.75, 1000000000000]";

  testWidgets(
      'a refused stack says so before the press and still exports the linear '
      'master', (tester) async {
    final handle = tester.ensureSemantics();
    darkroom.validationError = refusal;
    darkroom.invalidStep = 1;
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    await pump(tester, root);
    await openExport(tester);

    // The stages that would REPLAY the refused stack are refused with it, on
    // screen and in the accessible name — the shape this sheet already uses for
    // a raster of a linear stage.
    expect(
      find.textContaining(
        'This stack does not validate, so only the linear master can be '
        'written',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(find.textContaining(refusal), findsWidgets);
    for (final stage in ['Final', 'After a step']) {
      final chip = tester.widget<SkotiqChip>(
        find.widgetWithText(SkotiqChip, stage),
      );
      expect(chip.enabled, isFalse, reason: '$stage must be refused');
      final data = tester
          .getSemantics(find.widgetWithText(SkotiqChip, stage))
          .getSemanticsData();
      expect(data.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
      expect(data.hasFlag(SemanticsFlag.isEnabled), isFalse);
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      expect(data.label, startsWith(stage));
      expect(data.label, contains(refusal));
    }

    // The linear stage is genuinely available, so it is available: it replays
    // nothing, and the sheet opens on it rather than on a disabled chip.
    final linear = tester
        .getSemantics(find.widgetWithText(SkotiqChip, 'Linear master'))
        .getSemanticsData();
    expect(linear.hasFlag(SemanticsFlag.isEnabled), isTrue);
    expect(linear.hasFlag(SemanticsFlag.isSelected), isTrue);
    expect(
      find.text(
        'The master\'s own pixels, untouched. The recipe rides along as '
        'provenance and is recorded as not applied.',
      ),
      findsOneWidget,
    );

    // And it exports: the refused step never reaches the pixels, and the recipe
    // travels with the file exactly as that caption promises.
    await tester.tap(find.text('Export'));
    await settle(tester);
    expect(darkroom.exportArgs, hasLength(1));
    final args = darkroom.exportArgs.single;
    expect((args['stage'] as Map)['kind'], 'linear');
    expect(args['sidecarPath'], '/tmp/skotiq-test/out.fits.nsrecipe');
    // The recipe rides along as provenance, refused step included: the export
    // sends the stack whole rather than quietly dropping what the engine
    // objected to.
    final sent =
        (jsonDecode(darkroom.exportRecipes.single) as Map<String, dynamic>);
    expect((sent['steps'] as List), hasLength(2));
    expect(find.textContaining('Written', findRichText: true), findsOneWidget);

    await drain(tester);
    handle.dispose();
  });

  testWidgets(
      'a failed export clears its progress and its Stop with the '
      'failure', (tester) async {
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    await pump(tester, root);
    await openExport(tester);

    final held = Completer<void>();
    darkroom.holdExport = held;
    darkroom.exportFailure = const DarkroomSeamException(
      'renderExport',
      refusal,
      refusal,
    );
    await tester.tap(find.text('Export'));
    await tester.pump();
    await tester.pump();

    // The render really is in the engine, and the sheet says so.
    expect(
      find.textContaining('Rendering the final stack at full resolution'),
      findsOneWidget,
    );
    expect(find.text('Stop'), findsOneWidget);

    held.complete();
    await settle(tester);

    // The failure is up — and the sheet behind it is idle. It used to keep the
    // progress line, the bar and a live Stop until the dialog was dismissed:
    // two contradictory claims about one export in one frame.
    expect(find.text('Export failed'), findsOneWidget);
    expect(find.textContaining('Rendering the'), findsNothing);
    expect(find.text('Stop'), findsNothing);
    expect(find.byType(SkotiqProgressBar), findsNothing);
    expect(find.textContaining('Written', findRichText: true), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byType(ErrorDialog),
        matching: find.text('Close'),
      ),
    );
    await settle(tester);
    await drain(tester);
  });

  testWidgets('a share sheet that refuses does not fail a written export', (
    tester,
  ) async {
    // The reveal/share is a hand-off to the OS that happens AFTER the engine
    // has written the file and the sheet has recorded the outcome. It used to
    // sit inside the try that reports the export, so on a platform whose share
    // sheet throws — a headless or sandboxed desktop target — a written,
    // sidecar-carrying export was reported to the operator as "Export failed",
    // over an outcome block that named the very file on disk.
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    await pump(tester, root);
    await openExport(tester);

    revealFailure = StateError('no activity found to handle the share intent');
    await tester.tap(find.text('Export'));
    await settle(tester);

    expect(revealCalls, 1, reason: 'the hand-off was attempted');
    // The export happened, and the sheet says so.
    expect(darkroom.exportArgs, hasLength(1));
    expect(find.textContaining('Written', findRichText: true), findsOneWidget);
    expect(
      find.textContaining('/tmp/skotiq-test/out.fits.nsrecipe'),
      findsOneWidget,
    );
    // And it is NOT reported as a failure.
    expect(find.text('Export failed'), findsNothing);
    expect(find.byType(ErrorDialog), findsNothing);
    // The smaller, true news is what the operator is told instead.
    expect(
      find.textContaining('could not be revealed or shared'),
      findsOneWidget,
    );
    // Nothing latched: the button is still live for a second export.
    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Export'),
          )
          .onPressed,
      isNotNull,
    );
    await drain(tester);
  });

  testWidgets(
      'a raster format the chosen stage cannot write says so on the '
      'button', (tester) async {
    // Reachable in three taps: a stack that ends stretched offers the rasters,
    // so JPEG can be selected; switching the stage back to the linear master
    // takes them away again and leaves JPEG selected. `_stageBlocked` is null
    // for that state — the STAGE is fine — so the button fell through to its
    // plain, unlabelled form: greyed, and announcing the bare word "Export"
    // over a bridge that publishes a node's name and nothing else.
    final handle = tester.ensureSemantics();
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    await pump(tester, root);
    await openExport(tester);

    await tester.tap(find.widgetWithText(SkotiqChip, 'JPEG'));
    await settle(tester);
    await tester.tap(find.widgetWithText(SkotiqChip, 'Linear master'));
    await settle(tester);

    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Export'),
          )
          .onPressed,
      isNull,
      reason: 'a linear master cannot be written as a JPEG',
    );
    final refusal = find.bySemanticsLabel(RegExp('^Export — '));
    expect(refusal, findsOneWidget);
    final label = tester.getSemantics(refusal).label;
    expect(label, contains('JPEG is unavailable for this stage'));
    expect(label, contains('FITS'));

    handle.dispose();
    Navigator.of(tester.element(find.text('Format'))).pop();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('a cancelled save picker exports nothing at all', (tester) async {
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    pickerAnswer = null;
    await pump(tester, root);
    await openExport(tester);

    await tester.tap(find.text('Export'));
    await settle(tester);

    expect(pickerCalls, hasLength(1));
    expect(darkroom.exportArgs, isEmpty);
    expect(find.textContaining('Written', findRichText: true), findsNothing);
    await drain(tester);
  });

  // ---------------------------------------------------------------------
  // Accessibility and the modal contract
  //
  // Driving the release build through AT-SPI turned up four things the widget
  // tree above could not see: the refused format chips announced no reason for
  // their refusal, Escape did nothing at all, the sheet stayed a 640-wide
  // centred card on a 430-wide phone, and hold-to-compare published a button
  // with no enabled state and no action — reported as `[DISABLED]`, unusable
  // from a keyboard or from assistive tech.
  // ---------------------------------------------------------------------

  SemanticsData dataFor(WidgetTester tester, Finder finder) =>
      tester.getSemantics(finder).getSemanticsData();

  testWidgets('a refused format announces the refusal, not just a grey chip', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final root = await seedRecipe([_step('background_extract')]);
    await pump(tester, root);
    await openExport(tester);

    final png = dataFor(tester, find.widgetWithText(SkotiqChip, 'PNG'));
    expect(png.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(png.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(png.hasFlag(SemanticsFlag.isEnabled), isFalse);
    // No live tap beside the disabled flag — the refusal is not a dare.
    expect(png.hasAction(SemanticsAction.tap), isFalse);
    // The reason rides the NAME, not the hint. Measured on the Linux release
    // bundle: every chip came back over AT-SPI as `'PNG' | button | desc: ''`,
    // so a hint-only reason reaches a screen reader on this platform not at
    // all. One node, still starting with the option's own word.
    expect(png.label, startsWith('PNG'));
    expect(png.label, contains('still linear ADU'));

    // An AVAILABLE option takes the same shape. Its reason used to ride the
    // hint, which the Linux AT-SPI bridge publishes nowhere — so the only
    // statement of what FITS writes was a hover tooltip.
    final fits = dataFor(tester, find.widgetWithText(SkotiqChip, 'FITS'));
    expect(fits.hasFlag(SemanticsFlag.isEnabled), isTrue);
    expect(fits.hasFlag(SemanticsFlag.isSelected), isTrue);
    expect(fits.hasAction(SemanticsAction.tap), isTrue);
    expect(fits.label, startsWith('FITS'));
    expect(fits.label, contains('Always available'));

    // Turning the auto stretch on makes the same chip readable as available.
    await tester.tap(find.byType(SkotiqSwitch).last);
    await settle(tester);
    final pngNow = dataFor(tester, find.widgetWithText(SkotiqChip, 'PNG'));
    expect(pngNow.hasFlag(SemanticsFlag.isEnabled), isTrue);
    expect(pngNow.hasAction(SemanticsAction.tap), isTrue);
    expect(pngNow.label, contains('16-bit PNG'));

    Navigator.of(tester.element(find.text('Export'))).pop();
    await settle(tester);
    await drain(tester);
    handle.dispose();
  });

  testWidgets('Escape closes the export sheet when nothing is running', (
    tester,
  ) async {
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    await pump(tester, root);
    await openExport(tester);
    expect(find.textContaining('Export "Draft"'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    expect(find.textContaining('Export "Draft"'), findsNothing);
    await drain(tester);
  });

  testWidgets('the export sheet names the phase it is actually in', (
    tester,
  ) async {
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    await pump(tester, root);
    await openExport(tester);

    // The save chooser is up and nothing has been sent to the engine.
    final chooser = Completer<String?>();
    pickerHold = chooser;
    final held = Completer<void>();
    darkroom.holdExport = held;
    await tester.tap(find.text('Export'));
    await tester.pump();
    await tester.pump();

    expect(darkroom.exportArgs, isEmpty);
    expect(
      find.textContaining('Waiting for the save chooser'),
      findsOneWidget,
    );
    // None of the render's vocabulary, because there is no render.
    expect(find.textContaining('Rendering the'), findsNothing);
    expect(find.text('Stop'), findsNothing);

    // Escape is answered with the truth about the chooser, not about a render.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
        find.textContaining('The save chooser is still open',
            findRichText: true),
        findsOneWidget);
    expect(
      find.textContaining('nothing has been sent to the engine yet'),
      findsWidgets,
    );

    // The operator names a file: now — and only now — the render is inside the
    // engine, and the sheet says so.
    chooser.complete('/tmp/skotiq-test/out.fits');
    await tester.pump();
    await tester.pump();
    expect(darkroom.exportArgs, hasLength(1));
    expect(
      find.textContaining('Rendering the final stack at full resolution'),
      findsOneWidget,
    );
    expect(find.text('Stop'), findsOneWidget);
    expect(find.textContaining('Waiting for the save chooser'), findsNothing);

    held.complete();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('Escape mid-export keeps the sheet up and says why', (
    tester,
  ) async {
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    await pump(tester, root);
    await openExport(tester);

    final held = Completer<void>();
    darkroom.holdExport = held;
    await tester.tap(find.text('Export'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Stop'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(find.textContaining('Export "Draft"'), findsOneWidget);
    expect(
      find.textContaining('This sheet stays up while the export runs',
          findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('nothing left to report its outcome to'),
      findsOneWidget,
    );

    // And it stops saying so once the render is out of the engine.
    held.complete();
    await settle(tester);
    expect(
      find.textContaining('This sheet stays up while the export runs',
          findRichText: true),
      findsNothing,
    );
    await drain(tester);
  });

  testWidgets('a phone gets the export sheet as a bottom sheet', (
    tester,
  ) async {
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    await pump(tester, root, size: const Size(430, 932));
    await openExport(tester);

    expect(find.byType(BottomSheet), findsOneWidget);
    final sheet = tester.getRect(find.byType(BottomSheet));
    // Anchored to the bottom edge and the full width of the viewport, not a
    // 640-wide card floating in the middle of a 430-wide screen.
    expect(sheet.left, closeTo(0, 0.5));
    expect(sheet.width, closeTo(430, 0.5));
    expect(sheet.bottom, closeTo(932, 0.5));

    Navigator.of(tester.element(find.text('Export'))).pop();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('a desktop window keeps the export sheet a centred dialog', (
    tester,
  ) async {
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    await pump(tester, root);
    await openExport(tester);

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(Dialog), findsWidgets);

    Navigator.of(tester.element(find.text('Export'))).pop();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('hold-to-compare is an operable toggle, not a dead button', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);
    await enterCompare(tester);
    await tester.tap(find.widgetWithText(SkotiqChip, 'Blink'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    final hold = find.text('Hold to see Warmer');
    expect(hold, findsOneWidget);
    final node = tester.getSemantics(hold);
    final data = node.getSemanticsData();
    expect(data.label, 'Hold to see Warmer');
    expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
    // The whole defect: `Semantics(button:)` with no `enabled` and no action
    // published a node the AT-SPI bridge reported as DISABLED.
    expect(data.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(data.hasFlag(SemanticsFlag.isEnabled), isTrue);
    expect(data.hasFlag(SemanticsFlag.hasToggledState), isTrue);
    expect(data.hasFlag(SemanticsFlag.isToggled), isFalse);
    expect(data.hasFlag(SemanticsFlag.isFocusable), isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(data.hasAction(SemanticsAction.longPress), isTrue);
    expect(data.hint, contains('activate'));

    // Operated the way assistive tech operates it: activate pins the other
    // recipe up, activate again releases it. A press-and-hold cannot be
    // performed at all from a keyboard or a screen reader.
    final owner = tester.binding.pipelineOwner.semanticsOwner!;
    owner.performAction(node.id, SemanticsAction.tap);
    await tester.pump();
    expect(find.text('Showing B'), findsOneWidget);
    expect(
      tester.getSemantics(hold).getSemanticsData().hasFlag(
            SemanticsFlag.isToggled,
          ),
      isTrue,
    );
    // The blink timer cannot take it away while it is pinned.
    await tester.pump(kDarkroomBlinkInterval * 2);
    expect(find.text('Showing B'), findsOneWidget);

    owner.performAction(tester.getSemantics(hold).id, SemanticsAction.tap);
    await tester.pump();
    expect(
      tester.getSemantics(hold).getSemanticsData().hasFlag(
            SemanticsFlag.isToggled,
          ),
      isFalse,
    );
    await drain(tester);
    handle.dispose();
  });

  testWidgets('side by side offers no hold control, having nothing to hold', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);
    await enterCompare(tester);

    // Both renders are already on screen, so pinning B changes nothing — and a
    // control that publishes an on/off state while changing nothing is a lie.
    expect(find.byKey(kDarkroomPreviewSurfaceKey), findsNWidgets(2));
    expect(find.text('Hold to see Warmer'), findsNothing);
    await drain(tester);
  });

  // ---------------------------------------------------------------------
  // The export sheet on a recipe with nothing in it, and the auto stretch as
  // a control that stays put.
  //
  // Measured on the release bundle before these landed: a zero-step recipe
  // offered "After a step" greyed out with its reason nowhere on the sheet and
  // nowhere in its accessible name, under a stage line reading "Every enabled
  // step…" over a History panel saying the recipe carries no operations; and
  // switching the auto stretch ON deleted the switch, the alert and every
  // sentence about the transfer, leaving a sheet identical to a genuinely
  // stretched stage with no way back.
  // ---------------------------------------------------------------------

  testWidgets('a zero-step recipe states WHY "After a step" is dead', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final root = await seedRecipe(const []);
    await pump(tester, root);
    await openExport(tester);

    final after = tester.widget<SkotiqChip>(
      find.widgetWithText(SkotiqChip, 'After a step'),
    );
    expect(after.enabled, isFalse);

    // On screen for a touch screen, which has neither hover nor a pointer.
    expect(
      find.textContaining('"After a step" is unavailable for this recipe',
          findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('there is no step to stop after'),
      findsOneWidget,
    );

    // And in the accessible name for a screen reader, because the hint does
    // not survive the Linux AT-SPI bridge.
    final data =
        dataFor(tester, find.widgetWithText(SkotiqChip, 'After a step'));
    expect(data.label, startsWith('After a step'));
    expect(data.label, contains('there is no step to stop after'));
    expect(data.hasFlag(SemanticsFlag.isEnabled), isFalse);
    expect(data.hasAction(SemanticsAction.tap), isFalse);

    Navigator.of(tester.element(find.text('Export'))).pop();
    await settle(tester);
    await drain(tester);
    handle.dispose();
  });

  testWidgets('the stage line counts the recipe rather than asserting steps', (
    tester,
  ) async {
    final empty = await seedRecipe(const [], name: 'Empty');
    await pump(tester, empty);
    await openExport(tester);

    expect(
      find.textContaining('Every enabled step, at the master\'s full'),
      findsNothing,
    );
    expect(
      find.textContaining('This recipe carries no steps, so the final stage '
          'applies nothing'),
      findsOneWidget,
    );

    Navigator.of(tester.element(find.text('Export'))).pop();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('the stage line says so when every step is switched off', (
    tester,
  ) async {
    final off = await seedRecipe([
      _step('background_extract', enabled: false),
      _step('stretch', enabled: false),
    ], name: 'All off');
    await pump(tester, off);
    await openExport(tester);

    expect(
      find.textContaining('All 2 steps in this recipe are switched off'),
      findsOneWidget,
    );

    Navigator.of(tester.element(find.text('Export'))).pop();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('the stage line counts only the enabled steps', (tester) async {
    final mixed = await seedRecipe([
      _step('background_extract'),
      _step('stretch', enabled: false),
    ], name: 'Mixed');
    await pump(tester, mixed);
    await openExport(tester);

    expect(find.textContaining('The 1 enabled step of 2'), findsOneWidget);

    Navigator.of(tester.element(find.text('Export'))).pop();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('the auto stretch switch stays put and can be turned back off', (
    tester,
  ) async {
    const switchLabel = 'Render the 8/16-bit files through the auto stretch';
    final root = await seedRecipe([_step('background_extract')]);
    await pump(tester, root);
    await openExport(tester);

    expect(find.text(switchLabel), findsOneWidget);
    expect(
      find.textContaining(
        'PNG, JPEG and TIFF are unavailable for this stage',
        findRichText: true,
      ),
      findsOneWidget,
    );

    await tester.tap(find.byType(SkotiqSwitch).last);
    await settle(tester);

    // The control that set it is still there, and still says what is set.
    expect(find.text(switchLabel), findsOneWidget);
    expect(
      tester.widget<SkotiqSwitch>(find.byType(SkotiqSwitch).last).value,
      isTrue,
    );
    expect(
      find.textContaining(
        'PNG, JPEG and TIFF are rendered through the auto stretch',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('rendered through the engine\'s own auto stretch'),
      findsOneWidget,
    );
    expect(
      tester.widget<SkotiqChip>(find.widgetWithText(SkotiqChip, 'PNG')).enabled,
      isTrue,
    );

    // Off again, in place, without touching the stage.
    await tester.tap(find.byType(SkotiqSwitch).last);
    await settle(tester);
    expect(
      tester.widget<SkotiqSwitch>(find.byType(SkotiqSwitch).last).value,
      isFalse,
    );
    expect(
      find.textContaining(
        'PNG, JPEG and TIFF are unavailable for this stage',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<SkotiqChip>(find.widgetWithText(SkotiqChip, 'PNG')).enabled,
      isFalse,
    );

    Navigator.of(tester.element(find.text('Export'))).pop();
    await settle(tester);
    await drain(tester);
  });

  testWidgets(
      'turning the stretch off under a chosen raster says Export is '
      'waiting on that choice', (tester) async {
    final root = await seedRecipe([_step('background_extract')]);
    await pump(tester, root);
    await openExport(tester);

    await tester.tap(find.byType(SkotiqSwitch).last);
    await settle(tester);
    await tester.tap(find.widgetWithText(SkotiqChip, 'PNG'));
    await settle(tester);
    await tester.tap(find.byType(SkotiqSwitch).last);
    await settle(tester);

    // A disabled chip renders the same whether or not it is the chosen one, so
    // the sheet names the format that is holding the export.
    expect(
      find.textContaining('PNG is still the chosen format, so Export stays '
          'off'),
      findsOneWidget,
    );
    final export = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Export'),
    );
    expect(export.onPressed, isNull);

    Navigator.of(tester.element(find.text('Export'))).pop();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('a stretched stage offers no auto-stretch switch at all', (
    tester,
  ) async {
    final root = await seedRecipe([
      _step('background_extract'),
      _step('stretch'),
    ]);
    await pump(tester, root);
    await openExport(tester);

    // Nothing to opt into: these pixels already carry a display mapping.
    expect(
      find.text('Render the 8/16-bit files through the auto stretch'),
      findsNothing,
    );
    expect(
      find.textContaining(
        'PNG, JPEG and TIFF are rendered through the auto stretch',
        findRichText: true,
      ),
      findsNothing,
    );

    Navigator.of(tester.element(find.text('Export'))).pop();
    await settle(tester);
    await drain(tester);
  });

  // ---------------------------------------------------------------------
  // Export over a master that is no longer readable
  // ---------------------------------------------------------------------

  /// What the engine says when the base master is not on disk any more, in the
  /// shape every base-master refusal takes: the path it was handed, in quotes.
  const missingMaster = DarkroomSeamException(
    'renderPreview',
    "cannot read '$_masterPath': No such file or directory (os error 2)",
    'os error 2',
  );

  testWidgets('an unreadable master disables Export and says why', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    darkroom.previewFailure = missingMaster;
    await pump(tester, root);
    await openExport(tester);

    // The two acts that recover the file, in the same words the viewport
    // behind the sheet is using — not a second vocabulary for one situation.
    // Scoped to the sheet's own alert, because the viewport under the modal is
    // showing that same sentence, which is the whole point of composing it from
    // the same helper.
    // Matched on the banner's own title rather than with `widgetWithText`:
    // SkotiqBanner paints title and message as ONE `Text.rich`, which
    // `find.text` (and so `widgetWithText`) does not read.
    final refusal = find.byWidgetPredicate(
      (widget) =>
          widget is SkotiqBanner &&
          widget.title == 'This master cannot be read',
    );
    expect(refusal, findsOneWidget);
    expect(
      find.descendant(
        of: refusal,
        matching: find.textContaining(
          'restore the master at that path, or re-integrate this night in '
          'Session Review',
        ),
      ),
      findsOneWidget,
    );

    final export = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Export'),
    );
    expect(export.onPressed, isNull);

    // And no chooser: an operator must not be asked to name a file for an
    // export that cannot produce one.
    await tester.tap(find.text('Export'), warnIfMissed: false);
    await settle(tester);
    expect(pickerCalls, isEmpty);

    Navigator.of(tester.element(find.text('Export'))).pop();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('an export that fails on the master names the way back', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await pump(tester, root);
    await openExport(tester);

    // The render succeeded and the file went missing after it: the sheet learns
    // about the file from its own export.
    darkroom.exportFailure = missingMaster;
    await tester.tap(find.text('Export'));
    await settle(tester);

    expect(pickerCalls, hasLength(1));
    expect(find.text('Export failed'), findsOneWidget);
    // The dialog's whole body: the engine's refusal and, under it, the two acts
    // that recover the file. It used to end at the OS error and a Close button.
    expect(
      find.text(
        "cannot read '$_masterPath': No such file or directory (os error 2)"
        '\n\nThe Darkroom only ever reads that file, so nothing here can put '
        'it back: restore the master at that path, or re-integrate this night '
        'in Session Review to write it again.',
      ),
      findsOneWidget,
    );

    // Close the failure dialog: the sheet underneath has stopped offering an
    // export over a file it has just been told it cannot read.
    await tester.tap(find.widgetWithText(SkotiqButton, 'Close').last);
    await settle(tester);

    expect(
        find.textContaining('This master cannot be read', findRichText: true),
        findsOneWidget);
    final export = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Export'),
    );
    expect(export.onPressed, isNull);
    await tester.tap(find.text('Export'), warnIfMissed: false);
    await settle(tester);
    expect(
      pickerCalls,
      hasLength(1),
      reason: 'a second chooser for the same missing file is a second dead end',
    );

    Navigator.of(tester.element(find.text('Export'))).pop();
    await settle(tester);
    await drain(tester);
  });

  // ---------------------------------------------------------------------
  // What compare, its picker and the export sheet publish
  // ---------------------------------------------------------------------

  /// Every semantics node in the tree, in the order assistive tech walks it.
  ///
  /// [SemanticsNode.visitChildren] answers PAINT order, which is not what a
  /// screen reader follows; the traversal sort is the thing under test here, so
  /// the walk asks for it by name.
  List<SemanticsNode> traversal(WidgetTester tester) {
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

  /// Where the node whose label contains [text] sits in the traversal walk.
  int traversalIndexOf(WidgetTester tester, String text) {
    final nodes = traversal(tester);
    for (var i = 0; i < nodes.length; i++) {
      if (nodes[i].getSemanticsData().label.contains(text)) return i;
    }
    fail('no semantics node carries "$text"');
  }

  SemanticsData? nodeLabelled(WidgetTester tester, String label) {
    for (final node in traversal(tester)) {
      final data = node.getSemanticsData();
      if (data.label == label) return data;
    }
    return null;
  }

  testWidgets(
      'the compare picker publishes its title, its close and each '
      'branch as separate nodes', (tester) async {
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);
    final handle = tester.ensureSemantics();

    await tester.tap(find.text('Compare with…'));
    await settle(tester);

    // The whole dialog reached AT-SPI as ONE button named "Compare with /
    // Close dialog", with the explanation and the branch button nested inside
    // it: the title was readable only as part of a control's name, and the one
    // control that closes the dialog had no node of its own to activate.
    final close = nodeLabelled(tester, 'Close dialog');
    expect(close, isNotNull);
    expect(close!.flagsCollection.isButton, isTrue);

    final title = nodeLabelled(tester, 'Compare with');
    expect(title, isNotNull, reason: 'the title has to read as text');
    expect(title!.flagsCollection.isButton, isFalse);

    expect(find.bySemanticsLabel('Warmer'), findsWidgets);
    handle.dispose();
    Navigator.of(tester.element(find.text('Compare with'))).pop();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('each compare pane publishes an image node naming its side', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);
    final handle = tester.ensureSemantics();
    await enterCompare(tester);
    await decodeFrames(tester);
    await settle(tester);

    // The single-recipe viewport publishes a rich image node; the two panes
    // whose whole purpose is reading a difference published none at all, so a
    // reader walking compare mode was never told a picture was there.
    final images = [
      for (final node in traversal(tester))
        if (node.getSemanticsData().flagsCollection.isImage)
          node.getSemanticsData().label,
    ];
    expect(images, hasLength(2));
    // Each names the pane it is — the side and the branch — and then carries
    // the same facts the single view's label does.
    expect(images[0], startsWith('Compare pane A of two.'));
    expect(images[0], contains('Rendered draft of Draft over m31_L.fits'));
    expect(images[0], contains('4×4'));
    expect(images[1], startsWith('Compare pane B of two.'));
    expect(images[1], contains('Rendered draft of Warmer over m31_L.fits'));
    handle.dispose();
    await drain(tester);
  });

  testWidgets('the step panels say whose steps they are while comparing', (
    tester,
  ) async {
    // Compare keeps the Recipe and History panels on screen, but both render
    // the A recipe and neither said so: a four-step stack sat beside panes
    // captioned "A · …" and "B · …" belonging, as far as the screen and the
    // accessibility tree went, to neither — while the picker's own copy
    // promises "what differs on screen is the interpretation".
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);

    // Nothing to qualify while one recipe is open.
    const owner = ValueKey('darkroom_compare_owner');
    expect(find.byKey(owner), findsNothing);

    final handle = tester.ensureSemantics();
    await enterCompare(tester);
    await decodeFrames(tester);
    await settle(tester);

    // One strip per VISIBLE SURFACE, which at this width is one: the desktop
    // split stacks the Recipe panel and the History stack in a single column.
    // Building the strip into each panel's body drew it twice, one above the
    // other, and published two identical nodes to a screen reader — which this
    // test used to pin as `findsNWidgets(2)`, mistaking a per-panel wrapper for
    // a per-surface heading. It is handed to the layout's own header slot now,
    // because the layout is the only thing that knows how many surfaces there
    // are: the phone's segmented view still gets its strip over whichever panel
    // is selected.
    expect(find.byKey(owner), findsOneWidget);
    expect(find.text('Pane A · Draft'), findsOneWidget);
    expect(
      find.text('B renders its own recipe and is not edited here.'),
      findsOneWidget,
    );

    final owners = [
      for (final node in traversal(tester))
        if (node.getSemanticsData().label.startsWith('Showing pane A'))
          node.getSemanticsData().label,
    ];
    expect(owners, hasLength(1));
    expect(owners.first, contains('Showing pane A, Draft.'));
    expect(owners.first, contains('pane B renders its own recipe'));
    handle.dispose();
    await drain(tester);
  });

  testWidgets('compare keeps the zoom controls and the readout', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);
    await enterCompare(tester);
    await decodeFrames(tester);
    await settle(tester);

    // 1:1 is the magnification an A/B noise comparison is for, and compare
    // offered no way to reach it: the toolbar was absent from the screen and
    // from the a11y tree, leaving the wheel as the only zoom at all.
    expect(find.widgetWithText(SkotiqButton, '1:1'), findsOneWidget);
    expect(find.widgetWithText(SkotiqButton, 'Fit'), findsOneWidget);
    expect(find.bySemanticsLabel('Zoom in'), findsOneWidget);
    expect(find.bySemanticsLabel('Zoom out'), findsOneWidget);
    expect(find.textContaining('% of master'), findsOneWidget);

    // And the controls drive the transform BOTH panes read, so the two sides
    // stay locked exactly as the picker promises.
    final shared = tester
        .widgetList<InteractiveViewer>(find.byType(InteractiveViewer))
        .first
        .transformationController!;
    final before = shared.value.getMaxScaleOnAxis();
    await tester.tap(find.widgetWithText(SkotiqButton, '1:1'));
    await tester.pump();
    expect(shared.value.getMaxScaleOnAxis(), isNot(before));
    for (final viewer in tester.widgetList<InteractiveViewer>(
      find.byType(InteractiveViewer),
    )) {
      expect(identical(viewer.transformationController, shared), isTrue);
    }
    await drain(tester);
  });

  // The two cases the Phase D critique measured over AT-SPI as out of order.
  //
  // Flutter's own traversal sort is what a `sortKey` or a structural change
  // could move, and both cases below show it already following visual order —
  // so these pin the seam this app owns. What the AT-SPI dumps recorded is one
  // level lower: the Linux bridge APPENDS a semantics node inserted after the
  // first update to the end of its parent's child list instead of re-sorting,
  // so exactly the controls that appear on a later state change (the compare
  // row, the export sheet's step dropdown and auto-stretch switch) read last
  // there while reading in place here.
  testWidgets('the compare controls are traversed where they are painted', (
    tester,
  ) async {
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);
    final handle = tester.ensureSemantics();
    await enterCompare(tester);
    await tester.tap(find.widgetWithText(SkotiqChip, 'Blink'));
    await settle(tester);

    // These four render at the TOP of the screen, above the image. They were
    // published as the LAST nodes in the tree, after every step card of the
    // History stack, so a reader met them only after walking the whole editor.
    final stack = traversalIndexOf(tester, 'Move Background extract');
    for (final control in const [
      'Side by side',
      'Blink',
      'Pause blink',
      'Hold to see',
    ]) {
      expect(
        traversalIndexOf(tester, control),
        lessThan(stack),
        reason: '"$control" is painted above the History stack',
      );
    }
    handle.dispose();
    await drain(tester);
  });

  testWidgets('a compare option publishes as an ENABLED button', (
    tester,
  ) async {
    // The one route into A/B compare read as dead to a screen reader: the
    // option's node carried `button: true` and no enabled state at all, and the
    // AT-SPI bridge publishes ENABLED only for a node that resolves one — so
    // Orca announced the row that opens compare as unavailable while a click on
    // the same row armed the comparison.
    final root = await seedRecipe([_step('background_extract')]);
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);
    final handle = tester.ensureSemantics();

    await tester.tap(find.text('Compare with…'));
    await settle(tester);

    final option = nodeLabelled(tester, 'Warmer');
    expect(option, isNotNull);
    expect(option!.flagsCollection.isButton, isTrue);
    expect(
      option.hasFlag(SemanticsFlag.hasEnabledState),
      isTrue,
      reason: 'a node with no enabled state reads as DISABLED over AT-SPI',
    );
    expect(option.hasFlag(SemanticsFlag.isEnabled), isTrue);
    // And it is operable, which is what makes the DISABLED announcement a lie.
    expect(option.hasAction(SemanticsAction.tap), isTrue);

    handle.dispose();
    Navigator.of(tester.element(find.text('Compare with'))).pop();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('the export sheet is traversed in the order it is painted', (
    tester,
  ) async {
    final root = await seedRecipe([_step('crop'), _step('background_extract')]);
    await pump(tester, root);
    final handle = tester.ensureSemantics();

    await tester.tap(find.text('Export…'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel(RegExp('^After a step — ')));
    await settle(tester);

    // The step dropdown renders directly under the Stage segment and above
    // Format; the auto-stretch switch renders above the closing provenance
    // paragraph. Both read in that order here.
    final format = traversalIndexOf(tester, 'Format');
    expect(traversalIndexOf(tester, '2. Background extract'), lessThan(format));
    expect(
      traversalIndexOf(tester, 'Render the 8/16-bit files'),
      lessThan(traversalIndexOf(tester, 'Every export carries this recipe')),
    );

    handle.dispose();
    Navigator.of(tester.element(find.text('Format'))).pop();
    await settle(tester);
    await drain(tester);
  });

  testWidgets('the branch strip keeps its place after it is rebuilt', (
    tester,
  ) async {
    // The branch strip is the ONE row in the bar that is torn down and rebuilt
    // on every navigation: `_chips` swaps the strip for a "Reading the
    // branches…" line while the controller reloads, so switching recipes
    // destroys the `_ChipStrip` element and builds a new one, while the
    // sibling strip beside it survives. A screen reader must still meet the
    // strip where it is painted — above Duplicate/Rename/Delete — and not at
    // the tail of the screen.
    //
    // The Linux bundle's AT-SPI tree walked the rebuilt strip LAST, after
    // every action in the bar. This pins the half of that ordering the repo
    // owns — Flutter's own compiled traversal order, which is what the engine
    // is handed — so a real regression above the bridge fails here.
    final root = await seedRecipe([_step('background_extract')]);
    final variant = await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    final router = await pump(tester, root);
    final handle = tester.ensureSemantics();

    expect(
      traversalIndexOf(tester, 'Branches over this master'),
      lessThan(traversalIndexOf(tester, 'Duplicate as variant')),
      reason: 'on the first open the strip already reads above the actions',
    );

    // Switch recipes the way a chip tap does. This is the step after which the
    // live AT-SPI tree moved the strip to the end of the walk.
    router.go('/darkroom?recipe=$variant');
    await settle(tester);

    expect(
      traversalIndexOf(tester, 'Branches over this master'),
      lessThan(traversalIndexOf(tester, 'Duplicate as variant')),
      reason: 'a rebuilt strip must be traversed where it is painted, not '
          'appended after every action in the bar',
    );

    handle.dispose();
    await drain(tester);
  });

  // D2-6, from the release bundle: the autopilot names its recipes
  // `Master · <filter> draft`, and the Save dialog opened pre-filled with
  // `Master_·_B_draft-final.fits`. That name is written to this disk, to a
  // `.nsrecipe` sidecar beside it, and from there to a watched folder or an
  // SFTP target — four filesystems and a wire, none of them this app's. Every
  // name the autopilot itself writes in the same directory is ASCII.
  testWidgets('the proposed file name is portable ASCII', (tester) async {
    final root = await seedRecipe(
      [_step('background_extract')],
      name: 'Master · B draft',
    );
    await pump(tester, root);
    await openExport(tester);

    await tester.tap(find.text('Export'));
    await settle(tester);

    expect(pickerCalls, hasLength(1));
    final proposed = pickerCalls.single['suggestedName'] as String;
    expect(proposed, 'Master_B_draft-final.fits');
    expect(
      proposed.codeUnits.every((u) => u >= 0x20 && u < 0x7f),
      isTrue,
      reason: 'the name goes onto three more filesystems after this one',
    );
    // And the recipe keeps the name it was given: the label in the app is not
    // rewritten to suit a file system.
    expect(find.text('Master · B draft'), findsWidgets);
    await drain(tester);
  });

  testWidgets('a name with nothing portable in it falls back to the id',
      (tester) async {
    final root = await seedRecipe(
      [_step('background_extract')],
      name: '· · ·',
    );
    await pump(tester, root);
    await openExport(tester);

    await tester.tap(find.text('Export'));
    await settle(tester);

    expect(
      pickerCalls.single['suggestedName'],
      'recipe-$root-final.fits',
      reason: 'a file called "_" names nothing',
    );
    await drain(tester);
  });
}
