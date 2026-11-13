// The channel mix on a Channel combine step: the weights of each narrowband
// master in red, green and blue, shown for a palette and stored for a custom
// mix.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_controller.dart';
import 'package:skotiq_app/screens/darkroom/darkroom_screen.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart' show TestBackendNotifier;
import '../../harness/mock_backend.dart';
import '../../harness/mock_database.dart';
import 'package:skotiq_app/router/darkroom_route.dart';

const String _masterPath = '/tmp/skotiq-test/ngc1499_Ha.fits';

const Map<String, dynamic> _sho = {
  'red': {'sii': 1.0},
  'green': {'hAlpha': 1.0},
  'blue': {'oiii': 1.0},
};

const Map<String, dynamic> _hoo = {
  'red': {'hAlpha': 1.0},
  'green': {'oiii': 1.0},
  'blue': {'oiii': 1.0},
};

const Map<String, dynamic> _catalogue = {
  'schemaVersion': 1,
  'ops': [
    {
      'id': 'channel_combine',
      'version': 1,
      'stage': 'linear',
      'summary': 'Combines per-filter masters into color.',
      'params': [
        {
          'name': 'palette',
          'displayName': 'Combination',
          'kind': 'enum',
          'required': true,
          'allowed': ['lrgb', 'sho', 'hoo', 'custom'],
          'independent': false,
          'summary': 'Which filters go to which color channel.',
        },
        {
          'name': 'mix',
          'displayName': 'Channel mix',
          'kind': 'channelMix',
          'required': false,
          'min': 0.0,
          'max': 2.0,
          'independent': false,
          'summary': 'How much of each narrowband master goes into red, '
              'green and blue.',
        },
      ],
    },
  ],
  'channelMixes': [
    {'palette': 'sho', 'name': 'SHO (Hubble palette)', 'mix': _sho},
    {'palette': 'hoo', 'name': 'HOO (bicolor)', 'mix': _hoo},
  ],
};

class _ScriptedDarkroom implements DarkroomSeam {
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
    final steps =
        (jsonDecode(recipeJson) as Map<String, dynamic>)['steps'] as List;
    return DarkroomRenderedPreview(
      width: 2,
      height: 2,
      isColor: true,
      rgba: Uint8List(2 * 2 * 4),
      report: {
        'encoding': {'applied': 'unit', 'sourceDomain': 'linear'},
        'level': {'level': 0, 'scaleFromMaster': 1.0},
        'report': {
          'steps': [
            for (var i = 0; i < steps.length; i++)
              {
                'index': i,
                'opId': (steps[i] as Map<String, dynamic>)['opId'],
                'outcome': 'applied',
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
  Future<Map<String, dynamic>> registry(Map<String, dynamic> args) async =>
      jsonDecode(jsonEncode(_catalogue)) as Map<String, dynamic>;

  @override
  Future<Map<String, dynamic>> cancel(Map<String, dynamic> args) async =>
      {'renderId': args['renderId'], 'running': false};
}

class _EmptyPhotometry extends DawnPhotometryResolver {
  _EmptyPhotometry()
      : super(
            coneSearch: (center, radiusDegrees, {maxMagnitude}) async =>
                const []);

  @override
  Future<DawnPhotometry> resolve(
          {required DawnMaster master, required WcsOverlay? wcs}) async =>
      const DawnPhotometry.unavailable('no catalog stars in this test');
}

Map<String, dynamic> _combine(
  String palette,
  List<String> roles, {
  Map<String, dynamic>? mix,
}) =>
    {
      'opId': 'channel_combine',
      'opVersion': 1,
      'enabled': true,
      'params': {
        'palette': palette,
        'inputs': [
          for (final role in roles) {'role': role, 'path': '/m/$role.fits'},
        ],
        if (mix != null) 'mix': mix,
      },
    };

const _narrowband = ['hAlpha', 'oiii', 'sii'];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late RecipesDao recipes;

  setUp(() {
    db = mockDatabase();
    recipes = RecipesDao(db);
  });
  tearDown(() => db.close());

  Future<int> seedRecipe(Map<String, dynamic> step) => recipes.create(
        baseMasterPath: _masterPath,
        name: 'NGC 1499 combine',
        stepsJson: jsonEncode([step]),
        createdBy: RecipeAuthor.user,
      );

  Future<void> pump(
    WidgetTester tester,
    int recipeId, {
    Size size = const Size(1400, 1600),
  }) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, mockBackend()),
        ),
        databaseProvider.overrideWithValue(db),
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '0.0.0-test', buildNumber: 0),
        ),
        darkroomSeamProvider.overrideWithValue(_ScriptedDarkroom()),
        dawnPhotometryResolverProvider.overrideWithValue(_EmptyPhotometry()),
      ],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      initialLocation: '/darkroom',
      routes: [
        GoRoute(
          path: '/darkroom',
          builder: (context, state) =>
              DarkroomScreen(scope: DarkroomScope.recipe(recipeId)),
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
  }

  /// Past the render and the save debounce, so the stored row is current.
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 600));
    }
  }

  Future<Map<String, dynamic>> storedParams(int id) async {
    final stored = await recipes.getById(id);
    final steps = jsonDecode(stored!.stepsJson) as List;
    return (steps.first as Map<String, dynamic>)['params']
        as Map<String, dynamic>;
  }

  Finder weightField(String what) => find.descendant(
        of: find.bySemanticsLabel('Weight of $what'),
        matching: find.byType(EditableText),
      );

  String totalOf(WidgetTester tester, String channel) => tester
      .widget<Text>(find.byKey(ValueKey('darkroom_mix_total_$channel')))
      .data!;

  test('a mix reads its rows, defaults a missing master to zero and writes '
      'every weight', () {
    final mix = DarkroomChannelMix.fromJson(_hoo)!;
    expect(mix.weight('red', 'hAlpha'), 1);
    expect(mix.weight('red', 'sii'), 0);
    expect(mix.roles, {'hAlpha', 'oiii'});
    expect(mix.total('green', _narrowband), 1);

    final edited = mix.withWeight('red', 'sii', 0.4);
    expect(edited.matches(mix, _narrowband), isFalse);
    expect(edited.matches(mix, const ['hAlpha', 'oiii']), isTrue);
    expect(edited.toJson(_narrowband)['red'],
        {'hAlpha': 1.0, 'oiii': 0.0, 'sii': 0.4});
    expect(DarkroomChannelMix.fromJson('sho'), isNull);
  });

  test('the catalogue carries the palettes as weights', () {
    final catalog = decodeDarkroomCatalog(
      jsonDecode(jsonEncode(_catalogue)) as Map<String, dynamic>,
    );
    expect([for (final p in catalog.channelMixes) p.shortName], ['SHO', 'HOO']);
    expect(catalog.ops.single.param('mix')!.kind, DarkroomParamKind.channelMix);
    expect(
      darkroomMixRolesOf(
        DarkroomStep.fromJson(_combine('sho', const ['sii', 'luminance', 'hAlpha']),
            index: 0),
      ),
      ['hAlpha', 'sii'],
    );
  });

  testWidgets('a palette shows its own weights and a changed one is stored as '
      'a custom mix', (tester) async {
    final id = await seedRecipe(_combine('sho', _narrowband));
    await pump(tester, id);
    await tester.tap(find.text('Parameters'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Channel mix'), findsOneWidget);
    expect(find.widgetWithText(SkotiqChip, 'SHO'), findsNWidgets(2));
    expect(totalOf(tester, 'red'), 'total 1');
    expect(tester.widget<EditableText>(weightField('SII in red')).controller.text,
        '1');
    expect(tester.widget<EditableText>(weightField('Ha in red')).controller.text,
        '0');

    await tester.enterText(weightField('Ha in red'), '0.6');
    await drain(tester);

    expect(find.text('Custom mix'), findsOneWidget);
    expect(totalOf(tester, 'red'), 'total 1.600');
    final params = await storedParams(id);
    expect(params['palette'], 'custom');
    expect(params['mix'], {
      'red': {'hAlpha': 0.6, 'oiii': 0.0, 'sii': 1.0},
      'green': {'hAlpha': 1.0, 'oiii': 0.0, 'sii': 0.0},
      'blue': {'hAlpha': 0.0, 'oiii': 1.0, 'sii': 0.0},
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets('a custom mix opens with its stored weights showing, and '
      'starting again from the palette stores the palette', (tester) async {
    final id = await seedRecipe(
      _combine('custom', _narrowband, mix: {
        'red': {'hAlpha': 0.7, 'sii': 0.3},
        'green': {'oiii': 1.0},
        'blue': {'oiii': 1.25},
      }),
    );
    await pump(tester, id);

    // No press on Parameters: a custom mix arrives open.
    expect(find.byKey(const ValueKey('darkroom_channel_mix')), findsOneWidget);
    expect(tester.widget<EditableText>(weightField('Ha in red')).controller.text,
        '0.700');
    expect(totalOf(tester, 'blue'), 'total 1.250');

    await tester.tap(find.byKey(const ValueKey('darkroom_mix_start_sho')));
    await drain(tester);
    var params = await storedParams(id);
    expect(params['palette'], 'sho');
    expect(params.containsKey('mix'), isFalse);

    // HOO has no place for the SII master, so its weights over three masters
    // are a custom mix.
    await tester.tap(find.byKey(const ValueKey('darkroom_mix_start_hoo')));
    await drain(tester);
    params = await storedParams(id);
    expect(params['palette'], 'custom');
    expect((params['mix'] as Map)['green'],
        {'hAlpha': 0.0, 'oiii': 1.0, 'sii': 0.0});
    expect(tester.takeException(), isNull);
  });

  testWidgets('one undo takes a changed weight back to the palette',
      (tester) async {
    final id = await seedRecipe(_combine('hoo', const ['hAlpha', 'oiii']));
    await pump(tester, id);
    await tester.tap(find.text('Parameters'));
    await tester.pump(const Duration(milliseconds: 100));
    // Two masters: the mix has no SII row.
    expect(weightField('SII in red'), findsNothing);

    await tester.enterText(weightField('OIII in red'), '0.25');
    await drain(tester);
    expect((await storedParams(id))['palette'], 'custom');

    await tester.tap(find.text('Undo'));
    await drain(tester);
    final params = await storedParams(id);
    expect(params['palette'], 'hoo');
    expect(params.containsKey('mix'), isFalse);
  });

  testWidgets('a custom mix with no weights says so and offers a start',
      (tester) async {
    final id = await seedRecipe(_combine('custom', _narrowband));
    await pump(tester, id);
    expect(find.textContaining('stores no weights yet'), findsOneWidget);
    expect(totalOf(tester, 'green'), 'total 0');
    expect(find.byKey(const ValueKey('darkroom_mix_start_sho')), findsOneWidget);
  });

  testWidgets('a combination without narrowband masters has no channel mix',
      (tester) async {
    final id = await seedRecipe(
      _combine('lrgb', const ['luminance', 'red', 'green', 'blue']),
    );
    await pump(tester, id);
    await tester.tap(find.text('Parameters'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Combination'), findsOneWidget);
    expect(find.text('Channel mix'), findsNothing);
  });

  testWidgets('a custom mix is scrolled into a short panel on arrival',
      (tester) async {
    final id = await seedRecipe(_combine('custom', _narrowband, mix: _sho));
    await pump(tester, id, size: const Size(1400, 760));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byKey(const ValueKey('darkroom_mix_total_red')).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('the mix fits a phone', (tester) async {
    final id = await seedRecipe(_combine('custom', _narrowband, mix: _sho));
    await pump(tester, id, size: const Size(420, 900));
    await tester.tap(find.text('History').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('darkroom_channel_mix')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
