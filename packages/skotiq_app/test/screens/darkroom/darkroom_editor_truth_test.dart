// What the Darkroom says about itself, in the four places it was saying
// something untrue.
//
//  * the RECIPE panel's provenance block named the author and the base master
//    and stopped there — the calibration record behind those pixels, which the
//    master FITS carries as CALWARN and the morning report prints in full, was
//    absent from the one screen where the interpretation is decided;
//  * the BRANCH bar's sibling sentence governed its verb by the wrong count, so
//    a three-master night read "1 of the other 2 carry a recipe";
//  * the COMPARE owner banner was built into each secondary panel's body, so on
//    a desktop — where both panels stack in ONE column — the operator read the
//    same strip twice and a screen reader walked two identical nodes;
//  * the load-failure empty state offered "Back to session review" and went to
//    Analytics > History, a different screen listing every night.
//
// Driven at widget level because that is where each of them lives: none needs
// pixels from the engine, and every one of them is a claim this screen makes.

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;

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

/// A calibration record with one clean slot and two the matcher warned about —
/// the shape a real night produces when the flat library has nothing close.
const String _warnedStatsJson = '''
{
  "framesIntegrated": 40,
  "framesRejected": 3,
  "totalIntegrationSec": 12000.0,
  "calibration": {
    "anchorUnreadable": false,
    "cosmeticCorrection": true,
    "masters": [
      {"kind": "dark", "path": "/cal/dark.fits", "applied": true,
       "quality": "exact", "stale": false, "mismatches": [], "unverified": []},
      {"kind": "flat", "path": null, "applied": false,
       "quality": "missing", "stale": false, "mismatches": [], "unverified": []},
      {"kind": "bias", "path": "/cal/bias.fits", "applied": true,
       "quality": "fallback", "stale": true,
       "mismatches": [{"dimension": "gain", "light": "120", "master": "0",
                       "withinTolerance": false}],
       "unverified": []}
    ]
  },
  "calibrationWarnings": []
}
''';

/// A Darkroom seam that answers one small render, so the screen reaches its
/// laid-out state without an engine.
class _FixedRender implements DarkroomSeam {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late RecipesDao recipes;
  late IntegratedMastersDao masters;

  setUp(() {
    db = mockDatabase();
    recipes = RecipesDao(db);
    masters = IntegratedMastersDao(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedMaster({required String statsJson}) => masters.insertMaster(
        targetId: null,
        name: 'M31 L',
        masterFitsPath: _masterPath,
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.batch,
        channels: 1,
        width: 64,
        height: 48,
        frameCount: 40,
        totalIntegrationSeconds: 12000,
        statsJson: statsJson,
      );

  Future<int> seedRecipe({int? masterId, String name = 'Draft'}) =>
      recipes.create(
        masterId: masterId,
        baseMasterPath: _masterPath,
        name: name,
        stepsJson: jsonEncode([_step('background_extract')]),
        createdBy: RecipeAuthor.autopilot,
      );

  /// The routes this screen is reached by, plus the two places its own controls
  /// navigate to — the destination is half of what is under test, so it has to
  /// be a real route rather than a swallowed push.
  final visited = <String>[];

  GoRouter buildRouter(String initialLocation) {
    visited.clear();
    return GoRouter(
      initialLocation: initialLocation,
      routes: [
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
        GoRoute(
          path: '/session-review',
          builder: (context, state) {
            visited.add('/session-review?${state.uri.query}');
            return const Scaffold(body: Text('session review'));
          },
        ),
        GoRoute(
          path: '/analytics',
          builder: (context, state) {
            visited.add('/analytics?${state.uri.query}');
            return const Scaffold(body: Text('analytics'));
          },
        ),
      ],
    );
  }

  Future<void> pump(
    WidgetTester tester,
    String location, {
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
        darkroomSeamProvider.overrideWithValue(_FixedRender()),
        dawnPhotometryResolverProvider.overrideWithValue(_emptyPhotometry()),
      ],
    );
    addTearDown(container.dispose);

    final router = buildRouter(location);
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
      await tester.pump(const Duration(milliseconds: 40));
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

  group('the sibling sentence agrees with its own count', () {
    // D2-03: the verb was governed by the count of OTHER masters while its
    // subject is the count that carry a recipe.
    test('one drafted sibling out of two takes the singular verb', () {
      expect(
        darkroomSiblingSummarySentence(drafted: 1, siblings: 2),
        contains('1 of the other 2 carries a recipe'),
      );
    });

    test('two drafted siblings out of three take the plural', () {
      expect(
        darkroomSiblingSummarySentence(drafted: 2, siblings: 3),
        contains('2 of the other 3 carry a recipe'),
      );
    });

    test('none drafted takes the plural', () {
      expect(
        darkroomSiblingSummarySentence(drafted: 0, siblings: 2),
        contains('0 of the other 2 carry a recipe'),
      );
    });

    test('a single undrafted sibling still agrees', () {
      expect(
        darkroomSiblingSummarySentence(drafted: 0, siblings: 1),
        contains('0 of the other 1 carry a recipe'),
      );
    });

    test('every sibling drafted says so instead of counting', () {
      expect(
        darkroomSiblingSummarySentence(drafted: 3, siblings: 3),
        contains('every one of them carries a recipe'),
      );
    });
  });

  group('the recipe panel states the calibration behind the pixels', () {
    // D2-02.
    testWidgets('a warned master shows its slots and the warnings', (
      tester,
    ) async {
      final masterId = await seedMaster(statsJson: _warnedStatsJson);
      final recipeId = await seedRecipe(masterId: masterId);
      await pump(tester, '/darkroom?recipe=$recipeId');
      await settle(tester);

      // Every slot the integration recorded, with whether the correction RAN —
      // "applied" and "missing" have to be distinguishable or the row says
      // nothing the operator can act on.
      expect(find.text('Calibration applied'), findsOneWidget);
      expect(find.text('Dark: applied · exact'), findsOneWidget);
      expect(find.text('Flat: not applied · missing'), findsOneWidget);
      expect(find.text('Bias: applied · fallback'), findsOneWidget);
      expect(
        find.text('Cosmetic correction: ran per light'),
        findsOneWidget,
      );

      // And the CALWARN truth itself, counted.
      expect(
        find.textContaining('recorded 2 calibration warnings'),
        findsOneWidget,
      );
      await drain(tester);
    });

    testWidgets('a master whose record raised nothing states no warning', (
      tester,
    ) async {
      final masterId = await seedMaster(statsJson: '{}');
      final recipeId = await seedRecipe(masterId: masterId);
      await pump(tester, '/darkroom?recipe=$recipeId');
      await settle(tester);

      // An empty record is not a clean bill of health and it is not a warning
      // either: the block simply has nothing to state.
      expect(find.text('Calibration applied'), findsNothing);
      expect(find.textContaining('calibration warning'), findsNothing);
      await drain(tester);
    });
  });

  group('the compare owner banner', () {
    // D3UI-4.
    testWidgets('renders once on a desktop, where both panels are visible', (
      tester,
    ) async {
      final root = await seedRecipe();
      await recipes.branchFrom(
        parentRecipeId: root,
        divergenceIndex: 1,
        name: 'Warmer',
      );
      await pump(tester, '/darkroom?recipe=$root');
      await settle(tester);
      await tester.tap(find.text('Compare with…'));
      await settle(tester);
      await tester.tap(find.widgetWithText(SkotiqCard, 'Warmer'));
      await settle(tester);

      // Recipe and History are stacked in one column at this width, and the
      // strip was built into each of them: two identical sentences, one above
      // the other, and two identical nodes in the accessibility tree.
      expect(
        find.byKey(const ValueKey('darkroom_compare_owner')),
        findsOneWidget,
      );
      expect(find.textContaining('Pane A · '), findsOneWidget);
      await drain(tester);
    });

    testWidgets('is absent when nothing is being compared', (tester) async {
      final root = await seedRecipe();
      await pump(tester, '/darkroom?recipe=$root');
      await settle(tester);

      expect(
        find.byKey(const ValueKey('darkroom_compare_owner')),
        findsNothing,
      );
      await drain(tester);
    });
  });

  group('the way out of a load failure goes where its label says', () {
    // D3UI-3.
    testWidgets('a master with no session offers the session list', (
      tester,
    ) async {
      // A master row that exists but has written no linear FITS: the load
      // fails, and no frame record joins it to a night.
      final masterId = await masters.insertMaster(
        targetId: null,
        name: 'M31 L (accumulating)',
        masterFitsPath: null,
        status: IntegratedMasterStatus.accumulating,
        accumulationMode: AccumulationMode.runningWeightedMean,
      );
      await pump(tester, '/darkroom?master=$masterId');
      await settle(tester);

      expect(find.text('Nothing to open in the Darkroom'), findsOneWidget);
      // It no longer promises a review it has not found.
      expect(find.text('Back to session review'), findsNothing);
      expect(find.text('Browse sessions'), findsOneWidget);

      await tester.tap(find.text('Browse sessions'));
      await settle(tester);
      expect(visited, contains('/analytics?tab=history'));
      await drain(tester);
    });

    testWidgets('a master folded from a night opens THAT night\'s review', (
      tester,
    ) async {
      final images = ImagesDao(db);
      final sessionId = await SessionsDao(db).createSession(
        ImagingSessionsCompanion.insert(
          startTime: DateTime.utc(2026, 8, 15, 22),
        ),
      );
      final imageId = await images.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/tmp/skotiq-test/m31_L_0001.fits',
          fileName: 'm31_L_0001.fits',
          exposureDuration: 300,
          capturedAt: DateTime.utc(2026, 8, 15, 22, 30),
          sessionId: Value(sessionId),
        ),
      );
      final masterId = await masters.insertMaster(
        targetId: null,
        name: 'M31 L (accumulating)',
        masterFitsPath: null,
        status: IntegratedMasterStatus.accumulating,
        accumulationMode: AccumulationMode.runningWeightedMean,
      );
      await masters.recordFoldedFrame(
        masterId: masterId,
        imageId: imageId,
        weight: 1.0,
        alignmentResidualPx: 0.4,
        accepted: true,
      );

      await pump(tester, '/darkroom?master=$masterId');
      await settle(tester);

      expect(find.text('Nothing to open in the Darkroom'), findsOneWidget);
      expect(find.text('Browse sessions'), findsNothing);
      expect(
        find.text('Open this night\'s session review'),
        findsOneWidget,
      );

      await tester.tap(find.text('Open this night\'s session review'));
      await settle(tester);
      // The night this master's pixels came from — not the list of every night.
      expect(visited, contains('/session-review?session=$sessionId'));
      await drain(tester);
    });
  });
}
