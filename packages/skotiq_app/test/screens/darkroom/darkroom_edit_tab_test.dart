// The Darkroom's Edit tab: every registered image grouped by target, the
// editor beside it, and combining a target's per-filter masters into color.

import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_controller.dart';
import 'package:skotiq_app/screens/darkroom/edit/channel_combine.dart';
import 'package:skotiq_app/screens/darkroom/edit/darkroom_image_library.dart';
import 'package:skotiq_app/screens/darkroom/edit/edit_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

/// A seam that answers the registry with a scripted composite plan and refuses
/// every render, so an editor opened here shows its error state rather than
/// reaching for the native engine.
class _CombineSeam implements DarkroomSeam {
  final registryCalls = <Map<String, dynamic>>[];
  Map<String, dynamic> Function(Map<String, dynamic> args)? answer;

  @override
  Future<Map<String, dynamic>> registry(Map<String, dynamic> args) async {
    registryCalls.add(args);
    final reply = answer;
    // Through JSON, as the native reply arrives: nested maps are then
    // Map<String, dynamic>, which is what the decoders check for.
    if (args['composite'] != null && reply != null) {
      return jsonDecode(jsonEncode(reply(args))) as Map<String, dynamic>;
    }
    return {'ops': const [], 'registered': const []};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<Never>.error(
        DarkroomSeamException(
          '${invocation.memberName}',
          'not available in this test',
          StateError('scripted'),
        ),
      );
}

Map<String, dynamic> _combinedReply(String referencePath) => {
      'masterPath': referencePath,
      'base': {'width': 64, 'height': 64},
      'draft': {
        'recipe': {
          'steps': [
            {
              'opId': 'channel_combine',
              'opVersion': 1,
              'params': {'palette': 'lrgb'},
              'enabled': true,
            },
            {
              'opId': 'stretch',
              'opVersion': 1,
              'params': <String, dynamic>{},
              'enabled': true,
            },
          ],
        },
        'notes': const [],
      },
      'composite': {
        'combined': true,
        'palette': 'lrgb',
        'paletteName': 'LRGB',
        'reason': 'L, R, G and B masters: luminance over RGB color',
        'alternatives': [
          {'palette': 'rgb', 'name': 'RGB'},
        ],
        'excluded': const [],
        'worstMedianOffsetPx': 0.31,
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late IntegratedMastersDao masters;
  late _CombineSeam seam;

  setUp(() {
    db = mockDatabase();
    masters = IntegratedMastersDao(db);
    seam = _CombineSeam();
  });
  tearDown(() => db.close());

  Future<int> seedMaster({
    required String name,
    required String filter,
    String? target,
    int channels = 1,
    String? path,
    DateTime? createdAt,
  }) =>
      masters.insertMaster(
        name: name,
        masterFitsPath: path ?? '/masters/${name.replaceAll(' ', '_')}.fits',
        status: IntegratedMasterStatus.finalized,
        accumulationMode: AccumulationMode.runningWeightedMean,
        channels: channels,
        width: 64,
        height: 64,
        frameCount: 10,
        totalIntegrationSeconds: 5400,
        filter: filter,
        settingsJson: target == null ? '{}' : jsonEncode({'target': target}),
        createdAt: createdAt,
      );

  Future<GoRouter> pump(
    WidgetTester tester, {
    String location = '/darkroom?tab=edit',
    Size size = const Size(1600, 1000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final router = GoRouter(
      initialLocation: location,
      routes: [
        GoRoute(
          path: '/darkroom',
          builder: (context, state) => Scaffold(
            backgroundColor: SkotiqColors.dark.background,
            body: const DarkroomEditTab(),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          darkroomSeamProvider.overrideWithValue(seam),
        ],
        child: MaterialApp.router(
          theme: SkotiqTheme.dark,
          routerConfig: router,
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 30));
    }
    return router;
  }

  group('the image library', () {
    IntegratedMaster master({
      required String name,
      String? filter,
      int? targetId,
      String settings = '{}',
      int channels = 1,
    }) =>
        IntegratedMaster(
          id: 1,
          targetId: targetId,
          name: name,
          masterFitsPath: '/m.fits',
          previewPngPath: null,
          sidecarPath: null,
          rejectionMapPath: null,
          status: IntegratedMasterStatus.finalized,
          accumulationMode: AccumulationMode.batch,
          channels: channels,
          width: 1,
          height: 1,
          frameCount: 1,
          totalIntegrationSeconds: 1,
          filter: filter,
          settingsJson: settings,
          statsJson: '{}',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        );

    test('a master is filed under its target row, its build, or its name', () {
      expect(
        darkroomMasterTargetName(
          master(name: 'x', targetId: 7, settings: '{"target":"M 31"}'),
          {7: 'NGC 891'},
        ),
        'NGC 891',
      );
      expect(
        darkroomMasterTargetName(
          master(name: 'NGC891 L', filter: 'L', settings: '{"target":"M 31"}'),
          const {},
        ),
        'M 31',
      );
      expect(
        darkroomMasterTargetName(
          master(name: 'NGC0891 · R', filter: 'R'),
          const {},
        ),
        'NGC0891',
      );
      expect(
        darkroomMasterTargetName(master(name: 'NGC891 RGB', filter: 'RGB'), {}),
        'NGC891',
      );
    });

    test('a color master that names no filter is Color', () {
      expect(darkroomMasterKind(master(name: 'x', channels: 3)), 'Color');
      expect(darkroomMasterKind(master(name: 'x', filter: 'Ha')), 'Ha');
    });
  });

  testWidgets(
      'every registered image is listed under its target, '
      'composites first', (tester) async {
    final l = await seedMaster(
      name: 'NGC891 L',
      filter: 'L',
      target: 'NGC891',
      createdAt: DateTime(2026, 10, 20, 9),
    );
    final r = await seedMaster(name: 'NGC891 R', filter: 'R', target: 'NGC891');
    final lrgb = await seedMaster(
      name: 'NGC891 LRGB',
      filter: 'LRGB',
      target: 'NGC891',
      channels: 3,
    );
    await seedMaster(name: 'M81 Ha', filter: 'Ha', target: 'M81');
    await pump(tester);

    expect(find.text('4 IMAGES · 2 TARGETS'), findsOneWidget);
    expect(find.text('NGC891'), findsOneWidget);
    expect(find.text('M81'), findsOneWidget);
    double top(int id) =>
        tester.getTopLeft(find.byKey(ValueKey('darkroom_edit_image_$id'))).dy;
    expect(top(lrgb), lessThan(top(l)));
    expect(top(l), lessThan(top(r)));
    expect(find.text('No recipe yet'), findsNWidgets(4));
    // Two builds of one filter are told apart by when they were built.
    expect(find.textContaining('built Oct 20'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('choosing an image opens it in the editor', (tester) async {
    final id =
        await seedMaster(name: 'NGC891 L', filter: 'L', target: 'NGC891');
    final router = await pump(tester);

    await tester.tap(find.byKey(ValueKey('darkroom_edit_image_$id')));
    await tester.pump();
    final uri = router.routerDelegate.currentConfiguration.uri;
    expect(uri.queryParameters, {'tab': 'edit', 'master': '$id'});
  });

  testWidgets(
      'an open image sits beside the list on a wide window, '
      'and alone on a narrow one', (tester) async {
    final id =
        await seedMaster(name: 'NGC891 L', filter: 'L', target: 'NGC891');
    await pump(tester, location: '/darkroom?tab=edit&master=$id');

    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel(RegExp(r'^NGC891 L master')),
      findsOneWidget,
    );
    final row = tester.getSemantics(
      find.bySemanticsLabel(RegExp(r'^NGC891 L master')),
    );
    expect(row.flagsCollection.isSelected, Tristate.isTrue);
    expect(find.byKey(const ValueKey('darkroom_editor_bar')), findsOneWidget);
    semantics.dispose();

    await pump(
      tester,
      location: '/darkroom?tab=edit&master=$id',
      size: const Size(1000, 900),
    );
    expect(
        find.byKey(const ValueKey('darkroom_edit_image_list')), findsNothing);
    expect(find.byKey(const ValueKey('darkroom_editor_bar')), findsOneWidget);
  });

  testWidgets('an empty library says where masters come from', (tester) async {
    await pump(tester);

    expect(find.text('No images to edit yet'), findsOneWidget);
    expect(find.text('Go to Targets'), findsOneWidget);
  });

  testWidgets('Combine channels needs a target with two per-filter masters',
      (tester) async {
    await seedMaster(name: 'NGC891 L', filter: 'L', target: 'NGC891');
    await seedMaster(
      name: 'NGC891 RGB',
      filter: 'RGB',
      target: 'NGC891',
      channels: 3,
    );
    await pump(tester);

    final button = tester.widget<SkotiqButton>(
      find.byKey(const ValueKey('darkroom_combine_channels')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('combining a target\'s masters writes a recipe and opens it',
      (tester) async {
    await seedMaster(
      name: 'NGC891 L',
      filter: 'L',
      target: 'NGC891',
      path: '/m/L.fits',
    );
    await seedMaster(
      name: 'NGC891 R',
      filter: 'R',
      target: 'NGC891',
      path: '/m/R.fits',
    );
    await seedMaster(
      name: 'NGC891 G',
      filter: 'G',
      target: 'NGC891',
      path: '/m/G.fits',
    );
    await seedMaster(
      name: 'NGC891 B',
      filter: 'B',
      target: 'NGC891',
      path: '/m/B.fits',
    );
    seam.answer = (_) => _combinedReply('/m/L.fits');
    final router = await pump(tester);

    await tester.tap(find.byKey(const ValueKey('darkroom_combine_channels')));
    await tester.pumpAndSettle();
    expect(find.text('Combine channels'), findsWidgets);
    expect(find.text('MASTERS'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('darkroom_combine_plan')));
    await tester.pumpAndSettle();
    final request = seam.registryCalls.last['composite'] as Map;
    expect(
      [for (final i in request['inputs'] as List) (i as Map)['filter']],
      ['L', 'R', 'G', 'B'],
    );
    expect(request.containsKey('palette'), isFalse);
    expect(find.textContaining('Combines as LRGB', findRichText: true),
        findsOneWidget);
    expect(find.textContaining('0.31 px', findRichText: true), findsOneWidget);
    // The alternative the plan offered is a choice now.
    expect(find.text('RGB'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('darkroom_combine_open')));
    await tester.pumpAndSettle();

    final recipes = await RecipesDao(db).listForMaster('/m/L.fits');
    expect(recipes, hasLength(1));
    final recipe = recipes.single;
    expect(recipe.name, 'NGC891 LRGB combine');
    expect(
      [for (final s in jsonDecode(recipe.stepsJson) as List) s['opId']],
      ['channel_combine', 'stretch'],
    );
    expect(
      router.routerDelegate.currentConfiguration.uri.queryParameters,
      {'tab': 'edit', 'recipe': '${recipe.id}'},
    );
  });

  testWidgets('a set with no color combination says why and writes nothing',
      (tester) async {
    await seedMaster(name: 'M81 Ha', filter: 'Ha', target: 'M81');
    await seedMaster(name: 'M81 L', filter: 'L', target: 'M81');
    seam.answer = (_) => {
          'composite': {
            'combined': false,
            'reason': 'Ha and L make no color combination',
            'alternatives': const [],
            'excluded': const [],
          },
        };
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('darkroom_combine_channels')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('darkroom_combine_plan')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('These masters do not combine', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('make no color combination', findRichText: true),
      findsOneWidget,
    );
    final open = tester.widget<SkotiqButton>(
      find.byKey(const ValueKey('darkroom_combine_open')),
    );
    expect(open.onPressed, isNull);
  });

  test('a plan reply that says combined but names no reference is refused', () {
    expect(
      () => DarkroomCombinePlan.fromReply({
        'composite': {'combined': true, 'palette': 'rgb'},
      }),
      throwsA(isA<DarkroomRecipeFormatException>()),
    );
  });

  test('a library target lists its newest single-channel master per filter',
      () {
    IntegratedMaster m(int id, String filter, int day, {int channels = 1}) =>
        IntegratedMaster(
          id: id,
          targetId: null,
          name: 'T $filter',
          masterFitsPath: '/m$id.fits',
          previewPngPath: null,
          sidecarPath: null,
          rejectionMapPath: null,
          status: IntegratedMasterStatus.finalized,
          accumulationMode: AccumulationMode.batch,
          channels: channels,
          width: 1,
          height: 1,
          frameCount: 1,
          totalIntegrationSeconds: 1,
          filter: filter,
          settingsJson: '{}',
          statsJson: '{}',
          createdAt: DateTime(2026, 10, day),
          updatedAt: DateTime(2026, 10, day),
        );
    final target = groupDarkroomLibrary([
      for (final master in [
        m(1, 'R', 20),
        m(2, 'R', 22),
        m(3, 'L', 21),
        m(4, 'RGB', 22, channels: 3),
      ])
        DarkroomLibraryImage(master: master, target: 'T'),
    ]).single;
    expect(
      [for (final i in target.channelMasters) i.master.id],
      [3, 2],
    );
  });
}
