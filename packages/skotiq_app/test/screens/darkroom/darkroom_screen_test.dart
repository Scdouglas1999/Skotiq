// Widget tests for the Darkroom editor screen.
//
// The screen is one rendering of one controller state, so these assert the
// things a reader of the code cannot see: that a remote client is told where
// the work lives instead of being shown an empty canvas, that a bad deep link
// explains itself, that every step card states what the render DID with it, and
// that a skip reason is on the card rather than behind the expander.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'dart:ui' show SemanticsAction, SemanticsFlag, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show OrdinalSortKey, SemanticsNode;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_controller.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_screen.dart';
import 'package:skotiq_app/screens/darkroom/edit/darkroom_editor.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';
import '../../harness/pump_app_screen.dart';

/// A Darkroom seam whose every reply the test writes.
class _ScriptedDarkroom implements DarkroomSeam {
  bool validateOk = true;
  String validateError = 'a linear operation cannot run after a stretch';
  Map<int, String> skipReasons = {};

  /// Per-step `measured` blocks, the way crop publishes `clampedToImage`.
  Map<int, Map<String, dynamic>> measurements = {};
  Completer<void>? holdPreview;

  /// `opId@opVersion` keys this scripted build does not register, keyed on the
  /// operation the way the engine's registry is. Both entry points then behave
  /// as the engine does: `validate` diagnoses every step and refuses the recipe,
  /// and `renderPreview` refuses before it touches a pixel.
  Set<String> unregisteredOps = {};

  /// When set, the next preview throws this instead of answering — the shape a
  /// master that moved off disk takes at the seam.
  Object? previewError;

  final List<Map<String, dynamic>> cancelArgs = [];

  static String _opKey(Map<String, dynamic> step) =>
      '${step['opId']}@${step['opVersion']}';

  int? _firstUnregistered(List<dynamic> steps) {
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i] as Map<String, dynamic>;
      if (unregisteredOps.contains(_opKey(step))) return i;
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>> validate({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
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
            'registered': !unregisteredOps
                .contains(_opKey(steps[i] as Map<String, dynamic>)),
            'valid': !unregisteredOps
                .contains(_opKey(steps[i] as Map<String, dynamic>)),
            if (unregisteredOps
                .contains(_opKey(steps[i] as Map<String, dynamic>)))
              'error': 'no operation registered as '
                  '${_opKey(steps[i] as Map<String, dynamic>)}',
          },
      ],
    };
  }

  @override
  Future<DarkroomRenderedPreview> renderPreview({
    required String recipeJson,
    required Map<String, dynamic> context,
  }) async {
    final hold = holdPreview;
    if (hold != null) {
      holdPreview = null;
      await hold.future;
    }
    final failure = previewError;
    if (failure != null) {
      previewError = null;
      throw failure;
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
      width: 2,
      height: 2,
      isColor: false,
      rgba: Uint8List(2 * 2 * 4),
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
                    ((steps[i] as Map<String, dynamic>)['enabled'] as bool) ==
                            false
                        ? 'disabled'
                        : (skipReasons.containsKey(i) ? 'skipped' : 'applied'),
                if (skipReasons.containsKey(i)) 'reason': skipReasons[i],
                if (measurements.containsKey(i)) 'measured': measurements[i],
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

  /// Operations this test appends to the registry below, for a shape the two
  /// fixed ones do not carry.
  List<Map<String, dynamic>> extraOps = [];

  @override
  Future<Map<String, dynamic>> registry(Map<String, dynamic> args) async {
    return {
      'schemaVersion': 1,
      'ops': [
        ...extraOps,
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

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ScriptedDarkroom darkroom;
  late SkotiqDatabase db;

  setUp(() {
    darkroom = _ScriptedDarkroom();
    db = mockDatabase();
  });

  Future<int> seedRecipe(List<Map<String, dynamic>> steps) {
    return RecipesDao(db).create(
      baseMasterPath: _masterPath,
      name: 'Draft',
      stepsJson: jsonEncode(steps),
      createdBy: RecipeAuthor.autopilot,
    );
  }

  Future<HarnessHandle> pump(
    WidgetTester tester,
    DarkroomScope scope, {
    Size size = const Size(1280, 800),
  }) async {
    final handle = await pumpAppScreen(
      tester,
      DarkroomScreen(scope: scope),
      size: size,
      database: db,
      settle: false,
      extraOverrides: [
        darkroomSeamProvider.overrideWithValue(darkroom),
        dawnPhotometryResolverProvider.overrideWithValue(_emptyPhotometry()),
      ],
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    return handle;
  }

  /// The step cards in the order assistive tech walks them, by operation.
  ///
  /// Each card's own node opens with its drag handle's "Reorder <operation>"
  /// and then carries the rest of the card's words, so the first line names the
  /// step the reader is standing on.
  List<String> stackReadingOrder(WidgetTester tester) {
    const prefix = 'Reorder ';
    return [
      for (final node in tester.semantics.simulatedAccessibilityTraversal())
        if (node.label.startsWith(prefix))
          node.label.split('\n').first.substring(prefix.length),
    ];
  }

  /// Each step card's operation paired with the ordinal it publishes to
  /// assistive tech, in the tree's own order.
  ///
  /// The ordinal is what pins the reading order to the recipe: siblings with no
  /// sort key are ordered by their rectangles, and the rectangles are wherever
  /// the reorder's animation had got to on the last frame the bridge was told
  /// about.
  List<(String, double?)> stackSortOrdinals(WidgetTester tester) {
    const prefix = 'Reorder ';
    final found = <(String, double?)>[];
    void visit(SemanticsNode node) {
      if (node.label.startsWith(prefix)) {
        final key = node.sortKey;
        found.add((
          node.label.split('\n').first.substring(prefix.length),
          key is OrdinalSortKey ? key.order : null,
        ));
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    return found;
  }

  /// The step cards' semantics node ids, in the tree's own order.
  ///
  /// Identity, not order: what this is for is proving that an order change
  /// leaves NO card holding the node it had before.
  List<int> stackNodeIds(WidgetTester tester) {
    const prefix = 'Reorder ';
    final found = <int>[];
    void visit(SemanticsNode node) {
      if (node.label.startsWith(prefix)) found.add(node.id);
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    return found;
  }

  /// The node the platform is handed under exactly [label], or null.
  ///
  /// Read off the published tree rather than off a widget: a control can carry
  /// the right properties in the widget tree and still publish them on a node
  /// that is not the one assistive tech lands on, which is the defect this
  /// file's step-card controls had.
  SemanticsNode? publishedNode(WidgetTester tester, String label) {
    SemanticsNode? found;
    void visit(SemanticsNode node) {
      if (found == null && node.label == label) found = node;
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    return found;
  }

  /// The label on the node that currently reports the keyboard focus.
  String? focusedLabel(WidgetTester tester) {
    String? found;
    void visit(SemanticsNode node) {
      if (found == null &&
          node.getSemanticsData().hasFlag(SemanticsFlag.isFocused)) {
        found = node.label;
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    return found;
  }

  /// Pump past every timer the screen arms — the render debounce, the write
  /// debounce and a toast's own dismissal — so teardown finds none pending.
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
  }

  testWidgets('a remote client is told where the work lives', (tester) async {
    final backend = NetworkBackend(
      serverHost: '10.0.0.8',
      serverPort: 8080,
      webSocketPort: 8080,
      autoConnectWebSocket: false,
    );
    addTearDown(backend.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          darkroomSeamProvider.overrideWithValue(darkroom),
          dawnPhotometryResolverProvider.overrideWithValue(_emptyPhotometry()),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
        child: const MaterialApp(
          home: DarkroomScreen(scope: DarkroomScope.recipe(1)),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.text('Open the Darkroom on the imaging host'),
      findsOneWidget,
    );
    expect(find.byKey(kDarkroomPreviewSurfaceKey), findsNothing);
  });

  testWidgets(
    'a --remote-host client that has not reached its rig is told where the '
    'work lives',
    (tester) async {
      // Launched as a client, backend still `Disconnected`: the pre-handshake
      // window, and again after every drop. Gating the editor on
      // `backendProvider is NetworkBackend` read false here, so the full editor
      // opened over the CLIENT's own database — recipes no dawn job on the rig
      // will ever read — while Delivery settings on the same launch correctly
      // refused, because it gates on the role.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(db),
            darkroomSeamProvider.overrideWithValue(darkroom),
            dawnPhotometryResolverProvider
                .overrideWithValue(_emptyPhotometry()),
            remoteClientLaunchProvider.overrideWithValue(true),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, DisconnectedBackend()),
            ),
          ],
          child: const MaterialApp(
            home: DarkroomScreen(scope: DarkroomScope.recipe(1)),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text('Open the Darkroom on the imaging host'),
        findsOneWidget,
      );
      expect(find.byKey(kDarkroomPreviewSurfaceKey), findsNothing);
    },
  );

  // `/darkroom` with no query is a RAIL DESTINATION now (wave 1 added it), not
  // only a malformed deep link. It used to answer "this link named neither a
  // recipe nor a master, so there is nothing to open" — a dead end reached by
  // pressing a nav item, while the host's masters sat in the database the
  // screen was refusing to read. It lists what there is to open instead.
  testWidgets('a link that names nothing lists what there is to open', (
    tester,
  ) async {
    await pump(tester, const DarkroomScope.empty());

    expect(
      find.textContaining('named neither a recipe nor a master'),
      findsNothing,
      reason: 'the rail must not lead to a refusal',
    );
    // The three lists 06-screens names for this screen.
    expect(find.text('Recipes'), findsOneWidget);
    expect(find.text('Sessions'), findsOneWidget);
    expect(find.text('Masters'), findsOneWidget);
    // The screen still says which screen it is.
    expect(find.text('Darkroom'), findsOneWidget);
  });

  testWidgets('an empty host offers ONE empty state, not a refusal', (
    tester,
  ) async {
    await pump(tester, const DarkroomScope.empty());
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text('No recipes yet'), findsOneWidget);
    // One button, and it goes somewhere on this screen rather than sending the
    // operator away to find a master by hand.
    expect(find.text('Browse masters'), findsOneWidget);
  });

  // Live: "Recipes 0" opened in front of "Sessions 66", so the first thing
  // the rail showed was an empty state with the content one tab over.
  testWidgets('with no recipes it opens on the first tab that has content', (
    tester,
  ) async {
    await SessionsDao(db).createSession(
      ImagingSessionsCompanion.insert(startTime: DateTime.utc(2026, 9, 14, 22)),
    );
    await pump(tester, const DarkroomScope.empty());
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('No recipes yet'), findsNothing);
    final sessionsTab = tester.widget<AdaptiveTabBar>(
      find.byType(AdaptiveTabBar),
    );
    expect(sessionsTab.selectedIndex, 1, reason: 'Sessions holds the content');

    // An explicit pick is kept, even when the picked tab is empty.
    await tester
        .tap(find.byKey(const ValueKey('darkroom_landing_tab_recipes')));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('No recipes yet'), findsOneWidget);
    expect(
      tester.widget<AdaptiveTabBar>(find.byType(AdaptiveTabBar)).selectedIndex,
      0,
    );
  });

  testWidgets('a recipe id with no row names the row AND a route back', (
    tester,
  ) async {
    await pump(tester, const DarkroomScope.recipe(4242));
    expect(find.text('Nothing to open in the Darkroom'), findsOneWidget);
    expect(
      find.textContaining('Recipe 4242 no longer has a row'),
      findsOneWidget,
    );
    // A recipe row that is gone names no master, so no session can be resolved
    // and the way out says where it actually goes.
    expect(find.text('Choose another image'), findsOneWidget);
  });

  testWidgets('a recipe renders its stack, its picture and its outcomes', (
    tester,
  ) async {
    final id = await seedRecipe([
      _step('background_extract'),
      _step('color_calibrate'),
    ]);
    await pump(tester, DarkroomScope.recipe(id));

    expect(find.text('Background extract'), findsOneWidget);
    expect(find.text('Color calibrate'), findsOneWidget);
    expect(find.byKey(kDarkroomPreviewSurfaceKey), findsOneWidget);
    expect(find.text('Applied by the last render'), findsNWidgets(2));
    // The zoom readout is about the master, never about the pyramid level.
    expect(find.textContaining('% of master'), findsOneWidget);
  });

  testWidgets('a skipped step shows its reason without being expanded', (
    tester,
  ) async {
    darkroom.skipReasons = {
      0: 'no photometric catalogue is installed, so the colour fit has nothing '
          'to regress against',
    };
    final id = await seedRecipe([_step('color_calibrate')]);
    await pump(tester, DarkroomScope.recipe(id));

    expect(find.text('Skipped, and here is why'), findsOneWidget);
    expect(
      find.textContaining('nothing to regress against'),
      findsOneWidget,
    );
    // The reason is on the card, not behind the expander.
    expect(find.text('Parameters'), findsNothing);
  });

  testWidgets('a clamped crop is applied-with-adjustment, never plain green', (
    tester,
  ) async {
    darkroom.measurements = {
      0: {
        'clampedToImage': {
          'level': 0,
          'imageWidth': 640,
          'imageHeight': 480,
          'requested': {'x': 0, 'y': 0, 'width': 1920, 'height': 1080},
          'applied': {'x': 0, 'y': 0, 'width': 640, 'height': 480},
          'recipeRect': {'x': 0, 'y': 0, 'width': 1920, 'height': 1080},
        },
      },
    };
    final id = await seedRecipe([_step('crop')]);
    await pump(tester, DarkroomScope.recipe(id));

    expect(find.text('Applied by the last render'), findsNothing);
    expect(
      find.textContaining('the crop asks for 1920×1080 at (0, 0)'),
      findsOneWidget,
    );
    expect(
      find.textContaining('only the part inside the frame'),
      findsOneWidget,
    );
  });

  testWidgets('the enable switch turns a step off without destroying it', (
    tester,
  ) async {
    final id = await seedRecipe([_step('background_extract')]);
    final scope = DarkroomScope.recipe(id);
    final handle = await pump(tester, scope);

    await tester.tap(find.byType(SkotiqSwitch).first);
    await tester.pump();

    final state = handle.container.read(darkroomControllerProvider(scope));
    expect(state.steps.single.enabled, isFalse);
    expect(state.steps, hasLength(1));

    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    // The CARD, not only the header: the screen once repainted its step count
    // while every card kept the state before the toggle.
    expect(
      tester.widget<SkotiqSwitch>(find.byType(SkotiqSwitch).first).value,
      isFalse,
    );
    expect(find.text('Off — the render skipped it'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('the viewport names the transfer the engine applied', (
    tester,
  ) async {
    final id = await seedRecipe([_step('background_extract')]);
    await pump(tester, DarkroomScope.recipe(id));

    // The engine names it; the strip must not claim otherwise.
    expect(
      find.textContaining('the engine did not name the display transfer'),
      findsNothing,
    );
    expect(
      find.textContaining('a screen transfer, applied for display only'),
      findsOneWidget,
    );
    expect(find.textContaining('over still-linear pixels'), findsOneWidget);
    // The lift's own numbers ride behind the tag beside it.
    expect(find.text('Screen transfer'), findsOneWidget);
  });

  testWidgets(
      'a refused reorder states itself on the panel, not only in a '
      'toast', (tester) async {
    final id = await seedRecipe([
      _step('background_extract'),
      _step('color_calibrate'),
    ]);
    final scope = DarkroomScope.recipe(id);
    final handle = await pump(tester, scope);

    darkroom.validateOk = false;
    await handle.container
        .read(darkroomControllerProvider(scope).notifier)
        .reorderStep(1, 0);
    await tester.pump();
    await tester.pump();

    // The card snaps back on its own, which reads as a dropped gesture; the
    // engine's sentence stays beside the stack it is about.
    expect(find.textContaining('That move was refused', findRichText: true),
        findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SkotiqBanner),
        matching: find.textContaining('linear operation cannot run after a '
            'stretch'),
      ),
      findsWidgets,
    );
    await drain(tester);
  });

  testWidgets('compare with no sibling publishes disabled and why', (
    tester,
  ) async {
    final id = await seedRecipe([_step('background_extract')]);
    await pump(tester, DarkroomScope.recipe(id));

    final handle = tester.ensureSemantics();
    final compare = find.bySemanticsLabel(RegExp('^Compare — '));
    expect(compare, findsOneWidget);
    final flags = tester.getSemantics(compare).flagsCollection;
    expect(flags.isButton, isTrue);
    // Tristate.isFalse, not Tristate.none: a control that publishes no enabled
    // state at all reads to assistive tech — and to the audit harness — as a
    // live button, however dimly it is painted.
    expect(flags.isEnabled, Tristate.isFalse);
    expect(
      tester.getSemantics(compare).label,
      contains('Duplicate this one as a variant'),
    );
    handle.dispose();
  });

  testWidgets(
      'the recipe panel scrolls visibly and keeps the skip reason '
      'above the fold', (tester) async {
    final id = await seedRecipe([_step('color_calibrate')]);
    await pump(tester, DarkroomScope.recipe(id));

    // An always-drawn scrollbar is what turns the card's cut-off last line
    // into "there is more below" rather than into a rendering fault.
    expect(
      find.descendant(
        of: find.byType(AdaptivePanelLayout),
        matching: find.byType(Scrollbar),
      ),
      findsWidgets,
    );
    final alert = find.textContaining(
        'Color calibration has no catalogue stars',
        findRichText: true);
    expect(alert, findsOneWidget);
    // Above the recipe's own identity block, which is the reference material
    // that pushed the reason past the fold at desktop width.
    expect(
      tester.getTopLeft(alert).dy,
      lessThan(tester.getTopLeft(find.text('Base master')).dy),
    );
  });

  testWidgets('the parameter controls come from the registry schema', (
    tester,
  ) async {
    final id = await seedRecipe([_step('background_extract')]);
    await pump(tester, DarkroomScope.recipe(id));

    expect(find.text('Parameters'), findsOneWidget);
    await tester.tap(find.text('Parameters'));
    await tester.pump();

    expect(find.text('sampleSpacing'), findsOneWidget);
    expect(
      find.text('Spacing between background sample boxes.'),
      findsOneWidget,
    );
    // 8…1024 is a range a slider can resolve, so it gets one.
    expect(find.byType(SkotiqSlider), findsOneWidget);
    // No stored value: the operation's own default is what renders.
    expect(find.text('default'), findsOneWidget);
  });

  testWidgets(
      'an integer range narrower than one step is a field, not a slider',
      (tester) async {
    // An integer parameter carries one slider division per integer it can
    // reach, so the rounded span IS the division count. `isSliderRanged` only
    // refuses min == max, so a range narrower than a single integer step —
    // 1 … 1.4 here — passed it and asked Material for ZERO divisions: an
    // assert in a debug build, and in a release one a NaN track geometry with
    // a nudge step of span ÷ 0. The range holds exactly one legal integer, so
    // it is not a slider at all; it renders as the typed field, which still
    // reads the value and takes it back.
    darkroom.extraOps = [
      {
        'id': 'narrow_integer',
        'version': 1,
        'stage': 'linear',
        'summary': 'Runs a whole number of passes.',
        'params': [
          {
            'name': 'passes',
            'kind': 'integer',
            'required': false,
            'min': 1.0,
            'max': 1.4,
            'default': 1,
            'independent': true,
            'summary': 'How many passes the operation runs.',
          },
        ],
      },
    ];
    final id = await seedRecipe([
      _step('narrow_integer', params: {'passes': 1}),
    ]);
    await pump(tester, DarkroomScope.recipe(id), size: const Size(1280, 1400));
    await tester.tap(find.text('Parameters'));
    await tester.pump();

    expect(
      tester.takeException(),
      isNull,
      reason: 'a zero-division slider is a Material assert, not a control',
    );
    expect(
      find.byType(SkotiqSlider),
      findsNothing,
      reason: 'one reachable integer is a readout, not a track to drag',
    );
    // The parameter is still on screen, still named, still typed into.
    expect(find.text('passes'), findsOneWidget);
    // The typed field, captioned with the bounds the track would have shown.
    expect(find.text('accepts 1 … 1.400'), findsOneWidget);
  });

  testWidgets('a refused reorder says why and leaves the order alone', (
    tester,
  ) async {
    final id = await seedRecipe([
      _step('background_extract'),
      _step('color_calibrate'),
    ]);
    final scope = DarkroomScope.recipe(id);
    final handle = await pump(tester, scope);

    darkroom.validateOk = false;
    await handle.container
        .read(darkroomControllerProvider(scope).notifier)
        .reorderStep(1, 0);
    await tester.pump();
    await tester.pump();

    final state = handle.container.read(darkroomControllerProvider(scope));
    expect(state.steps.map((s) => s.opId), [
      'background_extract',
      'color_calibrate',
    ]);
    expect(
      find.textContaining('linear operation cannot run after a stretch'),
      findsWidgets,
    );
    await drain(tester);
  });

  testWidgets('a committed reorder moves the card in the reading order too', (
    tester,
  ) async {
    final id = await seedRecipe([
      _step('crop'),
      _step('background_extract'),
      _step('denoise'),
      _step('stretch'),
    ]);
    final scope = DarkroomScope.recipe(id);
    // Tall enough that every card is laid out: the reading order of cards the
    // list has not built yet says nothing about the order of the ones it has.
    final handle = await pump(tester, scope, size: const Size(1400, 1600));
    final semantics = tester.ensureSemantics();

    expect(stackReadingOrder(tester), [
      'Crop',
      'Background extract',
      'Denoise',
      'Stretch',
    ]);
    final idsBefore = stackNodeIds(tester).toSet();

    // The move the engine accepts: denoise above background extract, both
    // linear-stage operations.
    await handle.container
        .read(darkroomControllerProvider(scope).notifier)
        .reorderStep(2, 1);
    await tester.pump();
    await tester.pump();

    final state = handle.container.read(darkroomControllerProvider(scope));
    expect(state.steps.map((s) => s.opId), [
      'crop',
      'denoise',
      'background_extract',
      'stretch',
    ]);
    // The panel PAINTS the new order; a reader walking the same panel used to
    // be handed a slot order the move had left behind, which is the only
    // account of the pipeline a screen reader gets.
    expect(stackReadingOrder(tester), [
      'Crop',
      'Denoise',
      'Background extract',
      'Stretch',
    ]);
    // And the order is STATED, not inferred from where the cards happen to sit:
    // the ordinals are the recipe's own positions, so a frame caught mid-move
    // publishes the same order as the settled one.
    expect(stackSortOrdinals(tester), [
      ('Crop', 0.0),
      ('Denoise', 1.0),
      ('Background extract', 2.0),
      ('Stretch', 3.0),
    ]);
    // And the order the framework publishes is the order the PLATFORM ends up
    // with. Measured on the release bundle 2026-08-31: a move re-inflates only
    // the cards whose index changed, so the untouched card keeps its
    // accessibility node while the moved ones get new ones — and the Linux
    // AT-SPI bridge leaves the node it already holds where it is and appends
    // the new ones after it. Moving the first of three steps down published
    // "Stretch, Denoise, Background extract" over a stack the panel painted,
    // and the engine ran, as "Denoise, Background extract, Stretch". No card
    // may survive an order change for the bridge to strand.
    final idsAfter = stackNodeIds(tester).toSet();
    expect(
      idsAfter.intersection(idsBefore),
      isEmpty,
      reason: 'a step card kept its accessibility node across a reorder, which '
          'is what leaves the platform holding the old reading order',
    );
    semantics.dispose();
    await drain(tester);
  });

  testWidgets('a long render offers a cooperative stop', (tester) async {
    final id = await seedRecipe([_step('background_extract')]);
    final scope = DarkroomScope.recipe(id);
    final held = Completer<void>();
    darkroom.holdPreview = held;
    final handle = await pump(tester, scope);

    expect(find.text('Stop render'), findsOneWidget);
    await tester.tap(find.text('Stop render'));
    await tester.pump();
    await tester.pump();

    // The stop is cooperative, so the button says so until the render answers.
    expect(find.text('Stopping…'), findsOneWidget);
    expect(darkroom.cancelArgs.single['op'], 'cancel');

    held.complete();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      handle.container.read(darkroomControllerProvider(scope)).rendering,
      isFalse,
    );
  });

  testWidgets('reset to linear switches every step off, and undo restores it', (
    tester,
  ) async {
    final id = await seedRecipe([
      _step('background_extract'),
      _step('color_calibrate'),
    ]);
    final scope = DarkroomScope.recipe(id);
    final handle = await pump(tester, scope);

    await tester.tap(find.text('Reset to linear'));
    await tester.pump();

    var state = handle.container.read(darkroomControllerProvider(scope));
    expect(state.isLinear, isTrue);
    expect(state.steps, hasLength(2));

    await tester.tap(find.text('Undo'));
    await tester.pump();
    state = handle.container.read(darkroomControllerProvider(scope));
    expect(state.steps.every((s) => s.enabled), isTrue);
    await drain(tester);
  });

  testWidgets('a phone reflows into segments instead of miniaturising', (
    tester,
  ) async {
    final id = await seedRecipe([_step('background_extract')]);
    await pump(
      tester,
      DarkroomScope.recipe(id),
      size: const Size(390, 844),
    );

    // The three regions become three segments; the image is the default one.
    expect(find.text('Image'), findsOneWidget);
    expect(find.text('Recipe'), findsWidgets);
    expect(find.text('History'), findsWidgets);
    expect(find.byKey(kDarkroomPreviewSurfaceKey), findsOneWidget);
  });

  testWidgets('a failed render labels the picture it left up, on the picture',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final id =
        await seedRecipe([_step('background_extract'), _step('stretch')]);
    final scope = DarkroomScope.recipe(id);
    // Tall enough that the Recipe panel's own "Render again" is on screen: a
    // tap aimed at a control below the fold hits nothing at all.
    final handle = await pump(tester, scope, size: const Size(1280, 1400));

    // A render landed, so there are pixels on screen.
    expect(find.byKey(kDarkroomPreviewSurfaceKey), findsOneWidget);
    expect(find.textContaining('The render did not finish'), findsNothing);

    // The master moves off disk and the next render fails. The preview is NOT
    // dropped — an editor that blanks on a failure loses the last picture the
    // operator could trust — so the picture that stays up has to say what it
    // is.
    darkroom.previewError = DarkroomSeamException(
      'renderPreview',
      "cannot read '$_masterPath': No such file or directory (os error 2)",
      StateError('missing master'),
    );
    await tester.tap(find.widgetWithText(SkotiqButton, 'Render again'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    final state = handle.container.read(darkroomControllerProvider(scope));
    expect(state.preview, isNotNull, reason: 'the previous frame stays up');
    expect(state.renderError, isNotNull);

    // On the viewport itself, not only in the Recipe panel: the tag, the
    // engine's own sentence, and a strip that stops describing the stale frame
    // as the current stack's.
    expect(find.text('Stale — the render did not finish'), findsOneWidget);
    expect(
      find.textContaining('No such file or directory'),
      findsWidgets,
    );
    expect(
      find.textContaining('Display transfer of the last render that finished'),
      findsOneWidget,
    );
    // And the picture's own name to a screen reader says it too. A label that
    // went on describing the current stack over superseded pixels would be the
    // same cry-wolf the strip above was fixed for.
    expect(
      tester
          .getSemantics(find.byKey(kDarkroomPreviewSurfaceKey))
          .getSemanticsData()
          .label,
      contains('the last render that finished'),
    );
    semantics.dispose();
    await drain(tester);
  });

  testWidgets('at phone width the failure is in the Image segment too',
      (tester) async {
    final id =
        await seedRecipe([_step('background_extract'), _step('stretch')]);
    final scope = DarkroomScope.recipe(id);
    await pump(tester, scope, size: const Size(430, 900));

    // Fail a render from the Recipe segment, then go back to the picture. At
    // this width the Recipe panel is a segment the operator is not looking at,
    // so a failure stated only there leaves the Image segment showing a stale
    // picture with nothing to say it is one.
    await tester.tap(find.text('Recipe').last);
    await tester.pump();
    darkroom.previewError = DarkroomSeamException(
      'renderPreview',
      "cannot read '$_masterPath': No such file or directory (os error 2)",
      StateError('missing master'),
    );
    final rerender = find.widgetWithText(SkotiqButton, 'Render again');
    await tester.ensureVisible(rerender);
    await tester.pump();
    await tester.tap(rerender);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    await tester.tap(find.text('Image'));
    await tester.pump();
    expect(find.byKey(kDarkroomPreviewSurfaceKey), findsOneWidget);
    expect(find.text('Stale — the render did not finish'), findsOneWidget);
    expect(find.textContaining('No such file or directory'), findsWidgets);
    await drain(tester);
  });

  testWidgets('a parameter slider follows the whole drag, not just its start',
      (tester) async {
    final id = await seedRecipe([_step('background_extract')]);
    final scope = DarkroomScope.recipe(id);
    // Tall enough that the expanded control is on screen: a gesture aimed
    // outside the window hits nothing at all.
    final handle = await pump(tester, scope, size: const Size(1280, 1400));

    await tester.tap(find.text('Parameters'));
    await tester.pump();
    final slider = find.byType(SkotiqSlider);
    expect(slider, findsOneWidget);

    // Press on the middle of the track and sweep right in held steps, the way
    // a finger or a mouse does. Every update in the gesture has to land: the
    // card used to be re-keyed by the first one, which tore its subtree down
    // and took the drag recognizer with it — the slider then took the value
    // under the pointer at press and ignored the rest of the sweep.
    num storedValue() => handle.container
        .read(darkroomControllerProvider(scope))
        .steps[0]
        .params['sampleSpacing'] as num;

    final box = tester.getRect(slider);
    final gesture = await tester.startGesture(
      Offset(box.left + 32, box.center.dy),
    );
    // The first move has to clear the drag slop before the slider hears
    // anything at all; everything after it is the rest of the gesture.
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    final afterFirstUpdate = storedValue();

    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();

    // Under the defect these two are equal: the first update re-keyed the card,
    // the subtree was rebuilt, and the recognizer that would have delivered the
    // rest of the sweep went with it.
    expect(storedValue(), greaterThan(afterFirstUpdate));
    await drain(tester);
  });

  testWidgets('the catalogue note is absent from a stack with no colour step',
      (tester) async {
    // The resolver is bound to an empty catalogue, so the photometry note is
    // set on every recipe. It is about `color_calibrate` and nothing else.
    final id = await seedRecipe([_step('background_extract')]);
    await pump(tester, DarkroomScope.recipe(id));

    expect(
        find.textContaining('Color calibration has no catalogue stars',
            findRichText: true),
        findsNothing);
    expect(find.textContaining('no catalogue star'), findsNothing);
  });

  testWidgets('a zero-step recipe reports no missing catalogue either', (
    tester,
  ) async {
    final id = await seedRecipe(const []);
    await pump(tester, DarkroomScope.recipe(id));

    expect(find.text('Nothing interpreted yet'), findsOneWidget);
    expect(
        find.textContaining('Color calibration has no catalogue stars',
            findRichText: true),
        findsNothing);
  });

  testWidgets('every step-card control publishes its name on ONE operable node',
      (tester) async {
    final id = await seedRecipe([
      _step('background_extract'),
      _step('color_calibrate'),
    ]);
    await pump(tester, DarkroomScope.recipe(id), size: const Size(1280, 1400));
    final semantics = tester.ensureSemantics();

    // Measured on the release bundle 2026-08-31: each of these came back
    // `['enabled', 'sensitive', 'showing']` with NO `focusable`, because the
    // name was published on a wrapper that excluded the node owning the focus.
    // A keyboard walk of one step card therefore stopped on unnamed panels for
    // the two move buttons, the parameters expander and remove, while only the
    // enable toggle — which is built as one node — announced itself.
    for (final label in [
      'Move Background extract down',
      'Background extract parameters',
      'Remove Background extract',
      'Background extract enabled',
    ]) {
      final node = publishedNode(tester, label);
      expect(node, isNotNull, reason: 'no node is published under "$label"');
      final data = node!.getSemanticsData();
      expect(
        data.hasFlag(SemanticsFlag.isFocusable),
        isTrue,
        reason: '"$label" names a node the keyboard cannot land on',
      );
      expect(data.hasFlag(SemanticsFlag.hasEnabledState), isTrue,
          reason: '"$label" states neither enabled nor disabled');
      expect(data.hasFlag(SemanticsFlag.isEnabled), isTrue, reason: label);
      expect(data.hasAction(SemanticsAction.tap), isTrue, reason: label);
    }

    // A control the stack's ends refuse still names itself, and still states
    // that it is disabled rather than going quiet.
    final upNode = publishedNode(
      tester,
      'Move Background extract up — it is already first in the stack (1 of 2)',
    );
    expect(upNode, isNotNull);
    final upData = upNode!.getSemanticsData();
    expect(upData.hasFlag(SemanticsFlag.hasEnabledState), isTrue);
    expect(upData.hasFlag(SemanticsFlag.isEnabled), isFalse);
    expect(upData.hasAction(SemanticsAction.tap), isFalse);

    semantics.dispose();
    await drain(tester);
  });

  testWidgets('Tab lands on the named step-card controls, not on panels',
      (tester) async {
    // Two steps, so at least one move button is live: a stack of one has both
    // its ends refused, and a disabled control is correctly outside the tab
    // order.
    final id = await seedRecipe([
      _step('background_extract'),
      _step('color_calibrate'),
    ]);
    await pump(tester, DarkroomScope.recipe(id), size: const Size(1280, 1400));
    final semantics = tester.ensureSemantics();

    // Walk the whole screen and collect what each stop CALLS ITSELF. The
    // failure this pins is not "focus never arrives" — it did — but "focus
    // arrives on a node with no name", which is what a screen-reader user is
    // read out.
    final reached = <String>{};
    for (var press = 0; press < 60; press++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final label = focusedLabel(tester);
      if (label != null && label.isNotEmpty) reached.add(label);
    }
    for (final label in [
      'Move Background extract down',
      'Background extract parameters',
      'Remove Background extract',
      'Background extract enabled',
    ]) {
      expect(
        reached,
        contains(label),
        reason: 'Tab never landed on a node named "$label"',
      );
    }

    semantics.dispose();
    await drain(tester);
  });

  testWidgets('every step card names its own controls to a screen reader', (
    tester,
  ) async {
    final id = await seedRecipe([
      _step('background_extract'),
      _step('color_calibrate'),
    ]);
    await pump(tester, DarkroomScope.recipe(id));

    final semantics = tester.ensureSemantics();
    // Four sibling nodes all reading "Parameters, button" name no operation.
    expect(
      find.bySemanticsLabel('Background extract parameters'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Remove Background extract'), findsOneWidget);
    expect(find.bySemanticsLabel('Remove Color calibrate'), findsOneWidget);
    // color_calibrate publishes no parameters in this registry, so its card has
    // no expander to name — and still has its own remove control.
    expect(find.bySemanticsLabel('Color calibrate parameters'), findsNothing);
    semantics.dispose();
  });

  testWidgets('a parameter slider says its name and its value', (tester) async {
    final id = await seedRecipe([
      _step('background_extract', params: {'sampleSpacing': 100.0}),
    ]);
    await pump(tester, DarkroomScope.recipe(id), size: const Size(1280, 1400));
    await tester.tap(find.text('Parameters'));
    await tester.pump();

    final semantics = tester.ensureSemantics();
    // The slider used to publish an empty name, no value and no value
    // interface: a screen-reader walk of a card with three of them heard
    // "slider" three times and learned nothing. The label and the readout were
    // sighted-only.
    final node = tester.getSemantics(find.byType(SkotiqSlider));
    expect(node.label, contains('sampleSpacing'));
    expect(node.label, contains('100'));
    expect(node.value, '100');
    // Assistive tech can move it, and is told where each step lands.
    expect(node.increasedValue, isNotEmpty);
    expect(node.decreasedValue, isNotEmpty);
    final data = node.getSemanticsData();
    expect(data.hasAction(SemanticsAction.increase), isTrue);
    expect(data.hasAction(SemanticsAction.decrease), isTrue);
    semantics.dispose();
    await drain(tester);
  });

  testWidgets('a slider announces the value the recipe HOLDS, not the clamp',
      (tester) async {
    // sampleSpacing accepts 8…1024 in this registry; the recipe holds 5000,
    // which the engine refuses by name and number on the card beside it.
    final id = await seedRecipe([
      _step('background_extract', params: {'sampleSpacing': 5000.0}),
    ]);
    await pump(tester, DarkroomScope.recipe(id), size: const Size(1280, 1400));
    await tester.tap(find.text('Parameters'));
    await tester.pump();

    final semantics = tester.ensureSemantics();
    final node = tester.getSemantics(find.byType(SkotiqSlider));
    // Measured on the release bundle 2026-08-31: with `scaleCount` = 500
    // stored and the card reading "parameter 'scaleCount' = 500 is outside
    // [1, 6]", the slider announced 6 — the position the Material slider is
    // pinned to, which is a number the engine never received.
    expect(node.value, contains('5000'));
    expect(node.label, contains('5000'));
    expect(node.value, contains('outside the accepted range'));
    // The thumb stays inside the track the widget accepts.
    expect(
        tester.widget<SkotiqSlider>(find.byType(SkotiqSlider)).value, 1024.0);
    semantics.dispose();
    await drain(tester);
  });

  testWidgets('"Use default" names the parameter it resets', (tester) async {
    final id = await seedRecipe([
      _step('background_extract', params: {'sampleSpacing': 100.0}),
    ]);
    await pump(tester, DarkroomScope.recipe(id), size: const Size(1280, 1400));
    await tester.tap(find.text('Parameters'));
    await tester.pump();

    final semantics = tester.ensureSemantics();
    // Unqualified, this is three words repeated once per parameter, and only
    // reading order says which one each belongs to — the defect this file's
    // Remove and Parameters controls were already fixed for.
    expect(
      find.bySemanticsLabel('Use default for sampleSpacing'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Use default'), findsNothing);
    semantics.dispose();
    await drain(tester);
  });

  testWidgets('a re-render keeps the previous frame instead of a spinner', (
    tester,
  ) async {
    final id = await seedRecipe([_step('background_extract')]);
    final scope = DarkroomScope.recipe(id);
    final handle = await pump(tester, scope);

    // The first frame has to be decoded before "kept" means anything.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.byType(InteractiveViewer), findsOneWidget);

    // A second render lands with a buffer the surface has not decoded yet.
    await handle.container
        .read(darkroomControllerProvider(scope).notifier)
        .refreshRender();
    await tester.pump();

    // The picture is still on screen, with a tag saying a newer frame is on its
    // way — rather than the canvas dropping to a spinner, which is what made a
    // parameter drag strobe.
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.text('New frame…'), findsOneWidget);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(find.text('New frame…'), findsNothing);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await drain(tester);
  });

  testWidgets('an unregistered step keeps its controls as separate nodes', (
    tester,
  ) async {
    darkroom.unregisteredOps = {'stretch@99'};
    final id = await seedRecipe([_step('stretch', opVersion: 99)]);
    await pump(tester, DarkroomScope.recipe(id));

    final semantics = tester.ensureSemantics();
    // The error case is exactly where the card used to collapse into one
    // ~200-character toggle: with no registered spec it had a single focusable
    // descendant and the whole card merged into it.
    expect(find.bySemanticsLabel('Stretch enabled'), findsOneWidget);
    expect(find.bySemanticsLabel('Remove Stretch'), findsOneWidget);
    // The card's own node opens with the reorder label, exactly as a
    // well-formed card's does, rather than the whole card being one control.
    expect(find.bySemanticsLabel(RegExp('^Reorder Stretch')), findsOneWidget);
    semantics.dispose();
    await drain(tester);
  });

  testWidgets('a step switched off stops blocking the stack', (tester) async {
    darkroom.unregisteredOps = {'stretch@99'};
    final id = await seedRecipe([
      _step('background_extract'),
      _step('stretch', opVersion: 99),
    ]);
    final scope = DarkroomScope.recipe(id);
    final handle = await pump(tester, scope);

    expect(
        find.textContaining('This stack does not validate', findRichText: true),
        findsOneWidget);

    handle.container
        .read(darkroomControllerProvider(scope).notifier)
        .toggleStep(1);
    await drain(tester);

    // The render replays enabled steps only, so a step that is off cannot make
    // the stack unrenderable — and the panel stops saying it does.
    expect(
        find.textContaining('This stack does not validate', findRichText: true),
        findsNothing);
    expect(find.textContaining('The render did not finish', findRichText: true),
        findsNothing);
    // The step itself still says what this build cannot do with it.
    expect(
      find.textContaining('This build registers no stretch@99'),
      findsWidgets,
    );
    expect(
      find.textContaining('left out of the render'),
      findsOneWidget,
    );
  });

  testWidgets(
      'a missing master names the next step; a step failure is left alone',
      (tester) async {
    final id = await seedRecipe([_step('background_extract')]);
    final scope = DarkroomScope.recipe(id);
    final handle = await pump(tester, scope, size: const Size(1280, 1400));

    // The master moves off disk. Every base-master refusal the engine raises
    // quotes the path, and that is the one failure the operator can act on —
    // outside this screen, which is why the failure card's own "Render again"
    // cannot be the whole answer.
    darkroom.previewError = DarkroomSeamException(
      'renderPreview',
      "cannot read '$_masterPath': No such file or directory (os error 2)",
      StateError('missing master'),
    );
    await tester.tap(find.widgetWithText(SkotiqButton, 'Render again'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    var state = handle.container.read(darkroomControllerProvider(scope));
    expect(state.renderError, contains('No such file or directory'));
    expect(state.renderError, contains('restore the master at that path'));
    expect(state.renderError, contains('re-integrate this night in Session'));

    // A step failure names no file, so it keeps the engine's sentence and is
    // not sent off to rebuild a master that is perfectly fine.
    darkroom.previewError = DarkroomSeamException(
      'renderPreview',
      'step 1: background_extract refused sampleSpacing=0',
      StateError('bad parameter'),
    );
    // Through the controller: the failure card above the button has grown by a
    // sentence, so the button it used to sit beside is now off the window.
    await handle.container
        .read(darkroomControllerProvider(scope).notifier)
        .refreshRender();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    state = handle.container.read(darkroomControllerProvider(scope));
    expect(state.renderError, contains('refused sampleSpacing=0'));
    expect(state.renderError, isNot(contains('re-integrate this night')));
    await drain(tester);
  });

  testWidgets('a long draft account collapses at a word, with a way to open it',
      (tester) async {
    const reason =
        'this master has 1 channel(s) and the colour fit needs three, so this '
        'draft covers the one channel it was given; to calibrate colour, '
        'combine the per-filter masters into a single three-channel master and '
        'draft that composite';
    final id = await RecipesDao(db).create(
      baseMasterPath: _masterPath,
      name: 'Draft',
      stepsJson: jsonEncode([_step('background_extract')]),
      createdBy: RecipeAuthor.autopilot,
      draftNotes: const [
        RecipeDraftNote(
          opId: 'color_calibrate',
          outcome: 'omitted',
          reason: reason,
        ),
      ],
    );
    await pump(tester, DarkroomScope.recipe(id));

    expect(
        find.textContaining('The draft left one operation out',
            findRichText: true),
        findsOneWidget);
    // Collapsed: whole words and an explicit mark, never a clause cut in half
    // by wherever the panel's scroll fold happens to land.
    //
    // Read off the banner rather than off a `Text`: SkotiqBanner paints its
    // title and message as ONE `Text.rich`, so `text.data` is null there and
    // the joined plain text would carry the title in front of the message this
    // test is measuring.
    final collapsed = tester
        .widgetList<SkotiqBanner>(find.byType(SkotiqBanner))
        .map((banner) => banner.message)
        .whereType<String>()
        .firstWhere((data) => data.startsWith('Color calibrate — omitted:'));
    expect(collapsed.endsWith('…'), isTrue, reason: collapsed);
    expect(collapsed, isNot(contains('draft that composite')));
    expect(collapsed.length, lessThan(reason.length));
    expect(
      RegExp(r'\S…$').hasMatch(collapsed) &&
          !RegExp(r'\s…$').hasMatch(collapsed),
      isTrue,
      reason: 'the cut lands after a whole word: $collapsed',
    );

    // The control that completes the sentence is INSIDE the alert that carries
    // it. Under the alert it was a separate row in the panel's scroll view, so
    // the truncated text sat above the fold and the button that said the rest
    // existed sat below it; sharing the alert's box is what makes them share a
    // viewport whatever the panel's height.
    final alert = find.ancestor(
      of: find.textContaining(
        'Color calibrate — omitted:',
        findRichText: true,
      ),
      matching: find.byType(SkotiqBanner),
    );
    expect(alert, findsOneWidget);
    final expand = find.descendant(
      of: alert,
      matching: find.widgetWithText(SkotiqButton, 'Show more'),
    );
    expect(expand, findsOneWidget);
    // Where inside the alert depends on the alert's width, and this panel is a
    // ~330px column: under that breakpoint [SkotiqAlert] lays its action
    // under the TITLE and above the message, at the alert's own width, because
    // beside the text it would be squeezed to half a phone-width alert and the
    // message would wrap down the whole screen. The panel viewport is 256px and
    // the account is longer than that in either arrangement, so the control is
    // scrolled to the way an operator scrolls to it — what this case is about
    // is that it travels WITH the sentence it completes rather than sitting in
    // a row of its own somewhere else in the panel, which is what the
    // `find.descendant(of: alert)` above pins.
    await tester.ensureVisible(expand);
    await tester.pump();
    await tester.tap(expand);
    await tester.pump();

    expect(find.textContaining('draft that composite'), findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.textContaining('draft that composite'),
          matching: find.byType(SkotiqBanner),
        ),
        matching: find.widgetWithText(SkotiqButton, 'Show less'),
      ),
      findsOneWidget,
    );
    await drain(tester);
  });

  testWidgets('each disclosure on the panel names what IT opens',
      (tester) async {
    const reason =
        'this master has 1 channel(s) and the colour fit needs three, so this '
        'draft covers the one channel it was given; to calibrate colour, '
        'combine the per-filter masters into a single three-channel master and '
        'draft that composite';
    // The second long account on the same panel: a render that refused, in the
    // engine's own words. (The third caller is the calibration-warnings card,
    // which needs a master-library row to speak.)
    darkroom.previewError = DarkroomSeamException(
      'renderPreview',
      "cannot read '$_masterPath': No such file or directory (os error 2); "
          'point the recipe at the master it was drafted over, or re-integrate '
          'this night and draft the master that comes out of it',
      StateError('missing master'),
    );
    final id = await RecipesDao(db).create(
      baseMasterPath: _masterPath,
      name: 'Draft',
      stepsJson: jsonEncode([_step('background_extract')]),
      createdBy: RecipeAuthor.autopilot,
      draftNotes: const [
        RecipeDraftNote(
          opId: 'color_calibrate',
          outcome: 'omitted',
          reason: reason,
        ),
      ],
    );
    await pump(tester, DarkroomScope.recipe(id), size: const Size(1400, 1600));

    final semantics = tester.ensureSemantics();
    // Measured on the release bundle 2026-08-31: two cards on this panel both
    // published `button: 'Show more'`, side by side, so a reader had reading
    // order and nothing else to tell one account from the other. The word on
    // screen stays "Show more" — it sits inside the alert whose sentence it
    // continues.
    expect(
      publishedNode(tester, "Show more about the draft's omissions"),
      isNotNull,
    );
    expect(
      publishedNode(tester, 'Show more about why the render did not finish'),
      isNotNull,
    );
    expect(publishedNode(tester, 'Show more'), isNull);
    semantics.dispose();
    await drain(tester);
  });

  testWidgets(
      'the "nothing to open" state keeps its way out as a control of its own',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, const DarkroomScope.recipe(4242));

    // The whole screen used to be ONE ~300-character button: the header's
    // title and subtitle, the empty state's title, the reason and this label
    // twice over, merged into the single fragment that carried a tap. Nothing
    // was named for an exact-name lookup to find, and an activation landed on a
    // node whose extents were the screen.
    final action = find.widgetWithText(
      SkotiqButton,
      'Choose another image',
    );
    final node = tester.getSemantics(action);
    final data = node.getSemanticsData();
    expect(data.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(data.label, contains('Choose another image'));
    expect(data.label, isNot(contains('Nothing to open in the Darkroom')));
    expect(data.label, isNot(contains('no longer has a row')));
    expect(node.rect.size, tester.getSize(action));

    // And the screen's own words read as text, on nodes that carry no role.
    final spoken = <String>[];
    void visit(SemanticsNode node) {
      if (node.isMergedIntoParent) return;
      final data = node.getSemanticsData();
      if (data.label.contains('no longer has a row')) {
        spoken.add(data.label);
        expect(data.hasFlag(SemanticsFlag.isButton), isFalse);
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);
    expect(spoken, isNotEmpty);
    handle.dispose();
    await drain(tester);
  });

  testWidgets('the rendered draft says what the picture is', (tester) async {
    final handle = tester.ensureSemantics();
    final id = await seedRecipe([_step('background_extract')]);
    await pump(tester, DarkroomScope.recipe(id));

    // The Darkroom's primary content published no node at all: a reader
    // walking the screen got the zoom toolbar and the encoding strip, and
    // nothing saying a picture was there or what it was of.
    final data = tester
        .getSemantics(find.byKey(kDarkroomPreviewSurfaceKey))
        .getSemanticsData();
    expect(data.hasFlag(SemanticsFlag.isImage), isTrue);
    // Every fact is the render's own: the branch and the master those pixels
    // belong to, the size the engine answered with, the domain it named and
    // the level it rendered from.
    expect(data.label, contains('Draft'));
    expect(data.label, contains('m31_L.fits'));
    expect(data.label, contains('2×2'));
    expect(data.label, contains('still-linear pixels'));
    expect(data.label, contains('pyramid level 0'));
    handle.dispose();
    await drain(tester);
  });

  testWidgets('a second identical refusal is announced again, not swallowed', (
    tester,
  ) async {
    final id = await seedRecipe([
      _step('background_extract'),
      _step('color_calibrate'),
    ]);
    final scope = DarkroomScope.recipe(id);
    final handle = await pump(tester, scope);
    final controller =
        handle.container.read(darkroomControllerProvider(scope).notifier);

    darkroom.validateOk = false;
    await controller.reorderStep(1, 0);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.byType(SkotiqToast), findsOneWidget);
    final first = handle.container.read(darkroomControllerProvider(scope));
    expect(first.reorderRefusalAttempt, 1);

    // Let the toast expire. The inline alert stays up — the reason is still
    // readable — which is exactly why the silence was easy to miss.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
    expect(find.byType(SkotiqToast), findsNothing);
    expect(find.textContaining('That move was refused', findRichText: true),
        findsOneWidget);

    // The same move, refused for the same reason, produces a byte-identical
    // sentence. Deduping on the words swallowed this one entirely, so the
    // operator's second press was never acknowledged.
    await controller.reorderStep(1, 0);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    final second = handle.container.read(darkroomControllerProvider(scope));
    expect(second.reorderRefusal, first.reorderRefusal);
    expect(second.reorderRefusalAttempt, 2);
    expect(find.byType(SkotiqToast), findsOneWidget);

    // And the inline alert still clears on the next successful edit.
    darkroom.validateOk = true;
    controller.toggleStep(0);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(
      handle.container.read(darkroomControllerProvider(scope)).reorderRefusal,
      isNull,
    );
    expect(find.textContaining('That move was refused', findRichText: true),
        findsNothing);
    await drain(tester);
  });

  testWidgets('the step the failure NAMES says so; its siblings do not', (
    tester,
  ) async {
    final id = await seedRecipe([
      _step('background_extract'),
      _step('color_calibrate'),
    ]);
    final scope = DarkroomScope.recipe(id);
    // Tall enough for both cards and the Recipe panel's own control.
    final handle = await pump(tester, scope, size: const Size(1280, 1400));

    // The engine's own sentence, word for word: it names the step by its
    // position in the recipe it was handed — counted from 1 — and the
    // operation at that position.
    darkroom.previewError = DarkroomSeamException(
      'renderPreview',
      'step 2 failed: color_calibrate@1: unsupported channel layout: a '
          '1-channel image, a colour master with 3 channels; combine a '
          'per-filter mono master first',
      StateError('unsupported channels'),
    );
    await tester.tap(find.widgetWithText(SkotiqButton, 'Render again'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    final state = handle.container.read(darkroomControllerProvider(scope));
    expect(state.renderError, isNotNull);
    expect(state.isFailedStep(1), isTrue);
    expect(state.isFailedStep(0), isFalse);

    // The failing card says it failed, with the engine's reason and without
    // the "step N failed" framing — the card IS that step. Its sibling keeps
    // the honest generic sentence, which is what BOTH cards used to carry.
    expect(
      find.textContaining('This step failed the render: unsupported channel '
          'layout'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'The last render did not finish, so nothing is reported for this step',
      ),
      findsOneWidget,
    );
    await drain(tester);
  });

  testWidgets('a failure this build cannot join to a step badges none', (
    tester,
  ) async {
    final id = await seedRecipe([
      _step('background_extract'),
      _step('color_calibrate'),
    ]);
    final scope = DarkroomScope.recipe(id);
    final handle = await pump(tester, scope, size: const Size(1280, 1400));

    // The index is in range, and the operation at it is NOT the one the
    // message names. Guessing from the number alone would badge a step the
    // engine never ran, so nothing is attributed.
    darkroom.previewError = DarkroomSeamException(
      'renderPreview',
      'step 1 failed: color_calibrate@1: unsupported channel layout',
      StateError('mismatched op'),
    );
    await tester.tap(find.widgetWithText(SkotiqButton, 'Render again'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }

    final state = handle.container.read(darkroomControllerProvider(scope));
    expect(state.renderError, isNotNull);
    expect(state.renderFailure, isNull);
    expect(
      find.textContaining(
        'The last render did not finish, so nothing is reported for this step',
      ),
      findsNWidgets(2),
    );
    await drain(tester);
  });
}
