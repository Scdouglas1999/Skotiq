// Two things the Darkroom did to a reader who pressed a control.
//
// PRESSING "Show more" SHOWED LESS. The Recipe panel is a fixed-height scroll
// region beside the History stack. Measured against the release bundle
// 2026-08-31 at 1600x1000 on an autopilot draft, opening "the draft's
// omissions" left the first paragraph sliced through the glyphs at the panel's
// bottom edge ("…and draft that composite"), the second omission entirely below
// it, and pushed the "Render / Up to date with the stack. / Render again" block
// that HAD been on screen out of view. The content was all reachable by wheel —
// it is a presentation failure, not a clipped one — and the only thing saying
// so was a 2-pixel scrollbar thumb.
//
// TYPING A NAME APPENDED IT. "Duplicate as variant" opens with the field
// focused and the suggested name in it, caret at the end and nothing selected,
// so a name typed straight into the focused field landed AFTER the suggestion:
// the branch was written as "Master · B draft variantHarder stretch", in the
// recipes table and on the branch bar both.
//
// Driven at widget level because both defects are this screen's own: the scroll
// position, the edges, and the controller's selection.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_controller.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_screen.dart';
import 'package:skotiq_app/screens/darkroom/edit/darkroom_editor.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_backend.dart';
import '../../harness/mock_database.dart';
import '../../harness/pump_app_screen.dart';

const String _masterPath = '/tmp/skotiq-test/m31_L.fits';

/// A seam that answers one small render and refuses nothing. Neither defect
/// here needs pixels from the engine to happen.
class _FixedRender implements DarkroomSeam {
  const _FixedRender();

  @override
  Future<Map<String, dynamic>> validate({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    final steps =
        (jsonDecode(recipeJson) as Map<String, dynamic>)['steps'] as List;
    return {
      'ok': true,
      'error': null,
      'steps': [
        for (var i = 0; i < steps.length; i++)
          {'index': i, 'registered': true, 'valid': true},
      ],
    };
  }

  @override
  Future<DarkroomRenderedPreview> renderPreview({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    return DarkroomRenderedPreview(
      width: 64,
      height: 48,
      isColor: false,
      rgba: Uint8List(64 * 48 * 4),
      report: {
        'encoding': {
          'requested': 'auto',
          'applied': 'screen',
          'sourceDomain': 'linear',
          'clampedSamples': 0,
          'screenTransfer': null,
          'screenTransferAffectsRecipe': false,
        },
        'level': {'level': 0, 'scaleFromMaster': 1.0},
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

/// The two omissions the dawn autopilot writes over a one-channel master, in
/// the words the release bundle printed. Long on purpose: the panel collapses
/// an account past [kDarkroomDraftNoteCollapsedChars], and the whole point is
/// what opening it does.
const List<RecipeDraftNote> _omissions = [
  RecipeDraftNote(
    opId: 'color_calibrate',
    outcome: 'omitted',
    reason: 'this master has 1 channel and the colour fit needs three, so this '
        'draft covers the one channel it was given; to calibrate colour, '
        'combine the per-filter masters into a single three-channel master and '
        'draft that composite',
  ),
  RecipeDraftNote(
    opId: 'crop',
    outcome: 'omitted',
    reason: 'the crop rectangle measured over this master is the whole '
        '1920x1080 frame, so it trims nothing: a draft carrying it would list '
        'a step that changes no pixel. Add a crop by hand to trim an edge.',
  ),
];

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

  Future<int> seedRecipe({
    String name = 'Draft',
    List<RecipeDraftNote> notes = const [],
  }) =>
      recipes.create(
        baseMasterPath: _masterPath,
        name: name,
        stepsJson: jsonEncode([_step('background_extract')]),
        createdBy: RecipeAuthor.autopilot,
        draftNotes: notes,
      );

  Future<void> pump(
    WidgetTester tester,
    int recipeId, {
    // The desktop layout the panel was measured in: it shares its column with
    // the History stack, so its viewport is a few hundred pixels and the
    // account does not fit — which is the whole case.
    Size size = const Size(1400, 900),
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
        darkroomSeamProvider.overrideWithValue(const _FixedRender()),
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

  /// Pump a dialog route and a round of controller work in. Deliberately not
  /// `pumpAndSettle`: the editor keeps an indeterminate progress animation up
  /// while a render is in the engine, so a settle never converges.
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

  group('the recipe panel\'s scroll region', () {
    test('says which edges have more behind them', () {
      ScrollMetrics at(double pixels) => FixedScrollMetrics(
            minScrollExtent: 0,
            maxScrollExtent: 400,
            pixels: pixels,
            viewportDimension: 200,
            axisDirection: AxisDirection.down,
            devicePixelRatio: 1.0,
          );

      expect(darkroomScrollEdges(at(0)), (above: false, below: true));
      expect(darkroomScrollEdges(at(120)), (above: true, below: true));
      expect(darkroomScrollEdges(at(400)), (above: true, below: false));

      // Content that fits fades at neither edge: a fade there would say there
      // is more to read when there is not.
      expect(
        darkroomScrollEdges(
          FixedScrollMetrics(
            minScrollExtent: 0,
            maxScrollExtent: 0,
            pixels: 0,
            viewportDimension: 200,
            axisDirection: AxisDirection.down,
            devicePixelRatio: 1.0,
          ),
        ),
        (above: false, below: false),
      );
    });

    test('fades only the edges that have more behind them', () {
      const opaque = 0xFF;
      int alphaAt(LinearGradient gradient, int index) =>
          (gradient.colors[index].a * 255).round();

      final none = darkroomRecipePanelEdgeMask(above: false, below: false);
      expect(alphaAt(none, 0), opaque);
      expect(alphaAt(none, none.colors.length - 1), opaque);

      final below = darkroomRecipePanelEdgeMask(above: false, below: true);
      expect(alphaAt(below, 0), opaque);
      expect(
        alphaAt(below, below.colors.length - 1),
        0,
        reason: 'the line at the bottom edge trails off rather than being cut '
            'clean through the glyphs',
      );

      final above = darkroomRecipePanelEdgeMask(above: true, below: false);
      expect(alphaAt(above, 0), 0);
      expect(alphaAt(above, above.colors.length - 1), opaque);
    });
  });

  testWidgets('opening a disclosure brings it into the panel\'s view',
      (tester) async {
    final recipe = await seedRecipe(notes: _omissions);
    await pump(tester, recipe);

    final disclosure = find.text('Show more');
    expect(disclosure, findsOneWidget);

    final region = find.ancestor(
      of: disclosure,
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(region.first).position;
    expect(
      position.pixels,
      0,
      reason: 'the panel opens at the top; the account is below the controls',
    );
    // Taken before the tap: `region` is anchored on the "Show more" label,
    // which the expansion renames, and the panel itself does not move.
    final viewportTop = tester.getRect(region.first).top;

    // SkotiqBanner puts the title and the message on one line and carries
    // its action on a row of its own at this width, so the account is taller
    // than the bordered alert it replaced and this control now starts below
    // the fold. Bring it on screen the way an operator scrolling to it would:
    // what is under test is what the EXPAND does to the scroll, not what
    // reaching the button costs.
    final expander = find.widgetWithText(SkotiqButton, 'Show more');
    await tester.ensureVisible(expander);
    await settle(tester);
    final beforeExpand = position.pixels;

    // Through the button rather than its label: the label is inside an
    // `ExcludeSemantics` the hit test does not stop at.
    await tester.tap(expander);
    await settle(tester);

    expect(find.text('Show less'), findsOneWidget);
    expect(
      position.pixels,
      isNot(beforeExpand),
      reason: 'this is the scroll that never happened: the expanded text grew '
          'past the fold and nothing moved to follow it',
    );

    // The account's heading, which sits at the top of the banner that just
    // grew. It is the banner's TITLE, painted in the same `Text.rich` as its
    // message, so it is matched as rich text.
    const heading = 'The draft left 2 operations out';
    final headingTop =
        tester.getRect(find.textContaining(heading, findRichText: true)).top;
    expect(
      headingTop,
      greaterThanOrEqualTo(viewportTop - 1),
      reason: 'the account must not be scrolled off the top of the panel to '
          'make room for its own tail',
    );
    expect(
      headingTop - viewportTop,
      lessThan(60),
      reason: 'its top sits at the panel\'s, so as much of the newly revealed '
          'text as fits is on screen',
    );

    await drain(tester);
  });

  testWidgets('a suggested branch name arrives selected', (tester) async {
    // The selection IS the assertion: the platform replaces a selected range
    // with what is typed, so a suggestion that arrives selected is one that
    // typing replaces and one arrow key keeps. `enterText` in a widget test
    // replaces the whole field whatever the selection is, which is exactly why
    // the appended name went unnoticed here for so long.
    final recipe = await seedRecipe();
    await pump(tester, recipe);

    await tester.tap(find.text('Duplicate as variant'));
    await settle(tester);

    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.controller.text, 'Draft variant');
    expect(
      field.focusNode.hasPrimaryFocus,
      isTrue,
      reason: 'the field is autofocused, so the next keystroke lands in it',
    );
    expect(
      field.controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 'Draft variant'.length),
      reason: 'a collapsed caret at the end is what appended a typed name to '
          'the suggestion instead of replacing it',
    );

    await tester.tap(find.text('Cancel'));
    await settle(tester);
    await drain(tester);
  });
}
