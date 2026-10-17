// The Darkroom's magnification readout and the four controls beside it, in both
// views that carry them.
//
// The percentage is the one number that says what the operator is looking at,
// and both halves of it were measured wrong in the running app:
//
//  * the SINGLE-recipe viewport opened saying "100% of master" while the fit
//    written from the surface's layout callback had laid a 1600x1200 render at
//    half that — the readout only started telling the truth once the operator
//    touched a zoom control;
//  * the A/B COMPARE readout never moved at all: both panes zoomed under the
//    shared transform while the toolbar stayed on its entry value.
//
// The controls themselves then failed the same way. Compare handed the row A's
// render alone, so a branch whose stack does not validate killed all four
// buttons over a B pane that was still drawing a picture and still zooming
// under the mouse wheel — seconds after the compare picker promised that zoom
// and pan stay locked together. Nothing in the tree said why: the AT-SPI bridge
// reported four buttons with no `enabled` state and no reason in any name,
// while every other refused control on the screen carries one.
//
// WHERE THE REFUSAL IS READ. The disabled assertions go through the published
// SEMANTICS NODE. `tooltip:` and `hint:` reach a pointer and a description; the
// Linux bridge folds neither into the accessible name, which is the one string
// every reader is handed.
//
// Driven at widget level because that is where the defect lives: the transform,
// the fit, the readout and the enabling are all this screen's, and none of them
// needs pixels from the engine to be wrong.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_controller.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_screen.dart';
import 'package:skotiq_app/utils/darkroom_navigation.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_backend.dart';
import '../../harness/mock_database.dart';
import '../../harness/pump_app_screen.dart';

const String _masterPath = '/tmp/skotiq-test/m31_L.fits';

/// The engine's refusal, in the shape the running app produced it: an Exact
/// field set outside a parameter's range, which the engine rejects before it
/// touches a pixel so no render comes back at all.
const String _refusal =
    "step 3 (stretch@1) has invalid parameters: stretch@1: parameter "
    "'symmetryPoint' = 77 is outside [0, 1]";

/// A render big enough that a fit is well under 1:1, which is the case the
/// readout got wrong: 100% and the fit only coincide on a picture that happens
/// to be smaller than its pane.
const int _previewWidth = 1600;
const int _previewHeight = 1200;

/// A Darkroom seam that answers one fixed render, and refuses the recipe rows
/// named in [refuse] the way the engine refuses an out-of-range parameter:
/// validation fails and the render throws, so that recipe never has pixels.
class _FixedRender implements DarkroomSeam {
  final Set<int> refuse;

  /// Whether the render says which pyramid level it answered at. An engine that
  /// does not leaves nothing to compute one screen pixel per master pixel from.
  final bool statesLevel;

  const _FixedRender({this.refuse = const <int>{}, this.statesLevel = true});

  /// The recipe row [recipeJson] describes. The controller writes it as `id`.
  bool _refused(String recipeJson) {
    final id = (jsonDecode(recipeJson) as Map<String, dynamic>)['id'];
    return refuse.contains(int.parse(id as String));
  }

  @override
  Future<Map<String, dynamic>> validate({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    final steps =
        (jsonDecode(recipeJson) as Map<String, dynamic>)['steps'] as List;
    final refused = _refused(recipeJson);
    return {
      'ok': !refused,
      'error': refused ? _refusal : null,
      'steps': [
        for (var i = 0; i < steps.length; i++)
          {'index': i, 'registered': true, 'valid': !refused},
      ],
    };
  }

  @override
  Future<DarkroomRenderedPreview> renderPreview({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    if (_refused(recipeJson)) {
      throw const DarkroomSeamException('renderPreview', _refusal, _refusal);
    }
    return DarkroomRenderedPreview(
      width: _previewWidth,
      height: _previewHeight,
      isColor: false,
      rgba: Uint8List(_previewWidth * _previewHeight * 4),
      report: {
        'encoding': {
          'requested': 'auto',
          'applied': 'screen',
          'sourceDomain': 'linear',
          'clampedSamples': 0,
          'screenTransfer': null,
          'screenTransferAffectsRecipe': false,
        },
        // Level 0: one rendered pixel per master pixel, so the readout is the
        // viewer's own scale and nothing else can explain a wrong percentage.
        if (statesLevel) 'level': {'level': 0, 'scaleFromMaster': 1.0},
        'report': {'steps': const <dynamic>[]},
      },
    );
  }

  @override
  Future<Map<String, dynamic>> renderExport({
    required String recipeJson,
    required Map<String, dynamic> args,
  }) async {
    throw UnimplementedError('this test never exports');
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
      ],
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

Map<String, dynamic> _step(String opId) => {
      'opId': opId,
      'opVersion': 1,
      'params': <String, dynamic>{},
      'enabled': true,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late RecipesDao recipes;

  setUp(() {
    db = mockDatabase();
    recipes = RecipesDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedRecipe({String name = 'Draft'}) => recipes.create(
        baseMasterPath: _masterPath,
        name: name,
        stepsJson: jsonEncode([_step('background_extract')]),
        createdBy: RecipeAuthor.autopilot,
      );

  Future<void> pump(
    WidgetTester tester,
    int recipeId, {
    Set<int> refuse = const <int>{},
    bool statesLevel = true,
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 900);
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
        darkroomSeamProvider.overrideWithValue(
          _FixedRender(refuse: refuse, statesLevel: statesLevel),
        ),
        dawnPhotometryResolverProvider.overrideWithValue(_emptyPhotometry()),
      ],
    );
    addTearDown(container.dispose);

    final router = GoRouter(
      initialLocation: '/darkroom?recipe=$recipeId',
      routes: [
        GoRoute(
          path: '/darkroom',
          builder: (context, state) {
            final raw = state.uri.queryParameters['recipe'];
            final id = raw == null ? null : int.tryParse(raw);
            return DarkroomScreen(
              scope: id == null
                  ? const DarkroomScope.empty()
                  : DarkroomScope.recipe(id),
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
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
  }

  /// Let `decodeImageFromPixels` answer: it runs on the engine, which the fake
  /// clock inside `testWidgets` never reaches, so without real time the surface
  /// stays on its first-frame spinner and never fits anything.
  Future<void> decodeFrames(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 80)),
    );
    await tester.pump();
    await tester.pump();
  }

  /// The percentage the toolbar prints, as an integer.
  int readout(WidgetTester tester) {
    final text = tester
        .widgetList<Text>(find.textContaining('% of master'))
        .single
        .data!;
    return int.parse(text.split('%').first);
  }

  /// What the picture on screen IS at, measured off the laid-out box rather
  /// than off the transform the readout also reads.
  ///
  /// A fit lays the whole render inside its pane, so the scale is the pane over
  /// the render on the tighter axis. Independent of every line under test: the
  /// readout has to agree with the geometry, not merely with itself.
  double fitScale(WidgetTester tester) {
    final box = tester.getSize(find.byKey(kDarkroomPreviewSurfaceKey).first);
    final x = box.width / _previewWidth;
    final y = box.height / _previewHeight;
    return x < y ? x : y;
  }

  /// [fitScale] as the whole percent the toolbar would print for it.
  int fitPercent(WidgetTester tester) => (fitScale(tester) * 100).round();

  /// Whether the screen publishes any node whose accessible NAME is [label].
  bool publishes(WidgetTester tester, String label) =>
      find.bySemanticsLabel(label).evaluate().isNotEmpty;

  /// How the control named [label] reads to assistive tech: true live, false
  /// refused, null when it publishes no enabled state at all.
  ///
  /// Null is the reading the AT-SPI bridge gave the four zoom buttons in the
  /// finding — `['sensitive','showing','visible']` and no `enabled` — which a
  /// screen reader announces as dimmed with nothing said about why.
  bool? enabledOf(WidgetTester tester, String label) {
    final found = find.bySemanticsLabel(label);
    expect(found, findsWidgets, reason: 'no node is named "$label"');
    return tester
        .getSemantics(found.first)
        .getSemanticsData()
        .flagsCollection
        .isEnabled
        .toBoolOrNull();
  }

  /// Open compare between the recipe on screen and the branch named [target].
  Future<void> compareWith(WidgetTester tester, String target) async {
    await tester.tap(find.text('Compare with…'));
    await settle(tester);
    await tester.tap(find.widgetWithText(SkotiqCard, target));
    await settle(tester);
    await decodeFrames(tester);
    await settle(tester);
  }

  testWidgets('the single-recipe readout states the fit it opened at', (
    tester,
  ) async {
    final root = await seedRecipe();
    await pump(tester, root);
    await decodeFrames(tester);
    await settle(tester);

    // The picture is laid out fitted — well under 1:1 for a 1600x1200 render in
    // this pane — and the readout said "100% of master" over it: the scale was
    // read with `getMaxScaleOnAxis`, whose maximum includes a Z column the
    // viewer never scales, so every view narrower than 1:1 measured as exactly
    // 1.0. "100%" is a claim about the operator's own pixels.
    expect(fitPercent(tester), lessThan(100));
    expect(readout(tester), fitPercent(tester));
    await drain(tester);
  });

  testWidgets('zooming in past 1:1 keeps the single-recipe readout honest', (
    tester,
  ) async {
    final root = await seedRecipe();
    await pump(tester, root);
    await decodeFrames(tester);
    await settle(tester);

    final fit = fitScale(tester);
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.bySemanticsLabel('Zoom in'));
      await tester.pump();
    }
    await tester.pump();

    // Four steps of 1.25 off the fit, and every intermediate value is a real
    // one: the readout used to sit on 100% for the whole run below 1:1 and then
    // jump straight to 128%.
    expect(readout(tester), (fit * 1.25 * 1.25 * 1.25 * 1.25 * 100).round());
    await drain(tester);
  });

  testWidgets('1:1 reaches one screen pixel per master pixel from a fit', (
    tester,
  ) async {
    final root = await seedRecipe();
    await pump(tester, root);
    await decodeFrames(tester);
    await settle(tester);
    // The view it starts from has to be the fit it is actually at, or the press
    // below proves nothing: a readout stuck on 100 makes 1:1 look reached from
    // a picture that is nowhere near it.
    expect(fitPercent(tester), lessThan(100));
    expect(readout(tester), fitPercent(tester));

    await tester.tap(find.widgetWithText(SkotiqButton, '1:1'));
    await tester.pump();
    await tester.pump();

    // The one magnification the control exists for. It was a no-op from any fit
    // below 1:1 over a level-0 render: the scale it asked for was the scale it
    // had just been told it was already at, so it returned having moved
    // nothing.
    expect(readout(tester), 100);
    await drain(tester);
  });

  testWidgets('the compare readout moves with the shared transform', (
    tester,
  ) async {
    final root = await seedRecipe();
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root);
    await tester.tap(find.text('Compare with…'));
    await settle(tester);
    await tester.tap(find.widgetWithText(SkotiqCard, 'Warmer'));
    await settle(tester);
    await decodeFrames(tester);
    await settle(tester);

    // Two panes, half the width each, so the fit is further below 1:1 than the
    // single view's — which is exactly the range the readout used to spend
    // entirely on "100% of master", frozen there through every press.
    final entry = fitScale(tester);
    expect(fitPercent(tester), lessThan(100));
    expect(readout(tester), fitPercent(tester));

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.bySemanticsLabel('Zoom in'));
      await tester.pump();
    }
    await tester.pump();

    expect(readout(tester), greaterThan(fitPercent(tester)));
    expect(readout(tester), (entry * 1.25 * 1.25 * 1.25 * 100).round());
    await drain(tester);
  });

  testWidgets('compare keeps zoom live on the pane that did render', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final root = await seedRecipe();
    await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    // A is the open recipe and it is the one the engine refuses, so this is the
    // reproduced state: pane A has no render at all, pane B has a picture.
    await pump(tester, root, refuse: {root});
    await compareWith(tester, 'Warmer');

    expect(find.text('This side did not render'), findsOneWidget);
    expect(find.byKey(kDarkroomPreviewSurfaceKey), findsOneWidget);

    // The picker promises zoom and pan stay locked together, and the wheel over
    // the surviving pane honours it — so four dead buttons above that pane were
    // the promise outliving its truth. One transform, one pane with pixels,
    // four live controls.
    //
    // The icon pair is read off the published node; the two labelled buttons
    // are read off the widget, because a live [SkotiqButton] merges its
    // annotation into the row rather than publishing a node of its own — the
    // reason the disabled branch has to build one, and the reason the tests
    // below can name them.
    for (final label in ['Zoom in', 'Zoom out']) {
      expect(
        enabledOf(tester, label),
        isTrue,
        reason: 'B has pixels under the shared transform, so $label moves the '
            'view A\'s failure cannot take away',
      );
    }
    for (final label in ['Fit', '1:1']) {
      expect(
        tester
            .widget<SkotiqButton>(
              find.widgetWithText(SkotiqButton, label),
            )
            .onPressed,
        isNotNull,
        reason: '$label operates over the pane that rendered',
      );
    }

    // And the readout says which side it measured, because the percentage is
    // now about B rather than about the side this editor is showing.
    final entry = readout(tester);
    expect(
      publishes(
          tester, 'Zoom $entry percent of the master, measured on pane B'),
      isTrue,
    );
    expect(
      publishes(tester, 'Zoom $entry percent of the master'),
      isFalse,
      reason: 'a percentage that names no side reads as being about A, which '
          'has no render at all',
    );
    expect(find.textContaining('% of master · B'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Zoom in'));
    await tester.pump();
    await tester.pump();
    expect(
      readout(tester),
      greaterThan(entry),
      reason: 'the control does what its enabled state claims',
    );

    // 1:1 over B's own level-0 render, which is the magnification an A/B noise
    // comparison exists for and the one the dead row put out of reach.
    await tester.tap(find.widgetWithText(SkotiqButton, '1:1'));
    await tester.pump();
    await tester.pump();
    expect(readout(tester), 100);
    await drain(tester);
    handle.dispose();
  });

  testWidgets('compare states why zoom is dead when neither pane rendered', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final root = await seedRecipe();
    final other = await recipes.branchFrom(
      parentRecipeId: root,
      divergenceIndex: 1,
      name: 'Warmer',
    );
    await pump(tester, root, refuse: {root, other});
    await compareWith(tester, 'Warmer');

    // Genuinely unavailable this time — and every one of the four says so, in
    // the name, through the seam the rest of the screen refuses with.
    for (final label in ['Zoom in', 'Zoom out', 'Fit', '1:1']) {
      expect(
        publishes(tester, label),
        isFalse,
        reason: '"$label" alone is the unexplained dead control',
      );
      final refused = unavailableControlName(
        label,
        kDarkroomCompareNeitherPaneRendered,
      );
      expect(enabledOf(tester, refused), isFalse);
    }
    expect(
      publishes(
        tester,
        'Zoom is unavailable — $kDarkroomCompareNeitherPaneRendered',
      ),
      isTrue,
      reason: 'the readout agrees with the controls rather than calling the '
          'magnification merely unknown',
    );
    await drain(tester);
    handle.dispose();
  });

  testWidgets('the single-recipe row states why zoom is dead after a failure', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final root = await seedRecipe();
    await pump(tester, root, refuse: {root});
    await settle(tester);

    const why = 'the render did not finish, so there are no pixels to zoom';
    for (final label in ['Zoom in', 'Zoom out', 'Fit', '1:1']) {
      expect(publishes(tester, label), isFalse);
      expect(enabledOf(tester, unavailableControlName(label, why)), isFalse);
    }
    expect(publishes(tester, 'Zoom is unavailable — $why'), isTrue);
    await drain(tester);
    handle.dispose();
  });

  testWidgets('1:1 alone refuses, in its own words, over a levelless render', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final root = await seedRecipe();
    await pump(tester, root, statesLevel: false);
    await decodeFrames(tester);
    await settle(tester);

    // Pixels are there and they move, so three of the four stay live; only the
    // control that needs the level is refused, and it says which fact is
    // missing rather than joining a row of dead buttons.
    expect(enabledOf(tester, 'Zoom in'), isTrue);
    expect(
      tester
          .widget<SkotiqButton>(
              find.widgetWithText(SkotiqButton, 'Fit'))
          .onPressed,
      isNotNull,
    );
    expect(
      enabledOf(
        tester,
        unavailableControlName('1:1', kDarkroomOneToOneNeedsLevel),
      ),
      isFalse,
    );
    // The readout agrees: a percentage OF THE MASTER cannot be computed from a
    // render that did not say what it is a scaling of.
    expect(publishes(tester, 'Zoom relative to the master is unknown'), isTrue);
    await drain(tester);
    handle.dispose();
  });
}
