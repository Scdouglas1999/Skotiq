// Your Sky is opt-in. Every surface that reads the atlas shows an honest
// "turn it on" state while it is off, turning it on asks first and names the
// disk cost, and the one-time notice deletes nothing without a confirmation.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/first_light/first_light_view.dart';
import 'package:skotiq_app/screens/your_sky/your_sky_screen.dart';
import 'package:skotiq_app/widgets/your_sky_off_notice.dart';
import 'package:skotiq_app/widgets/your_sky_opt_in.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/mock_database.dart' show mockDatabase;

class _Science extends ScienceSettingsNotifier {
  _Science(this._value);

  ScienceSettings _value;
  final enabledWrites = <bool>[];

  @override
  Future<ScienceSettings> build() async => _value;

  @override
  Future<void> setFeatureEnabled(ScienceFeature feature, bool enabled) async {
    if (feature != ScienceFeature.skyAtlas) return;
    enabledWrites.add(enabled);
    _value = _value.copyWith(skyAtlasEnabled: enabled);
    state = AsyncData(_value);
  }
}

class _RecordingAtlas extends SkyAtlasService {
  _RecordingAtlas(SkotiqDatabase db)
      : super(
          dao: SkyAtlasDao(db),
          seam: const BridgeSkyAtlasSeam(),
          logger: LoggingService(),
          atlasRootResolver: () async => '/nonexistent/q1-atlas',
        );

  int deletes = 0;

  @override
  Future<void> deleteAllData() async => deletes++;
}

void main() {
  Future<_Science> pump(
    WidgetTester tester,
    Widget child, {
    bool enabled = false,
    List<Override> extra = const [],
  }) async {
    final science = _Science(ScienceSettings(skyAtlasEnabled: enabled));
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          scienceSettingsProvider.overrideWith(() => science),
          skyAtlasRegionsProvider.overrideWith(
            (ref) => Stream.value(const <SkyAtlasRegionRow>[]),
          ),
          skyAtlasCoverageProvider.overrideWith(
            (ref) => Stream.value(const <AtlasTileCoverage>[]),
          ),
          skyAtlasTotalsProvider.overrideWith((ref) async => null),
          ...extra,
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return science;
  }

  testWidgets('Your sky says it is off and offers to turn it on', (
    tester,
  ) async {
    final science = await pump(tester, const YourSkyView());
    expect(find.text('Your sky is off'), findsOneWidget);
    expect(find.textContaining('2 to 3 GiB on a typical night'), findsOneWidget);

    await tester.tap(find.text('Turn on Your sky'));
    await tester.pumpAndSettle();
    expect(find.text('Turn on Your sky?'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('stops growing at 25 GiB'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(science.enabledWrites, [true]);
    expect(find.text('Your sky is off'), findsNothing);
  });

  testWidgets('declining the prompt leaves Your sky off', (tester) async {
    final science = await pump(tester, const YourSkyView());
    await tester.tap(find.text('Turn on Your sky'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(science.enabledWrites, isEmpty);
    expect(find.text('Your sky is off'), findsOneWidget);
  });

  testWidgets('with Your sky on, the atlas shows instead', (tester) async {
    await pump(tester, const YourSkyView(), enabled: true);
    expect(find.text('Your sky is off'), findsNothing);
  });

  testWidgets('First Light names what Your sky is needed for', (tester) async {
    await pump(
      tester,
      const FirstLightView(),
      extra: [
        firstLightCandidatesProvider.overrideWith(
          (ref) => Stream.value(const <TransientDetectionRow>[]),
        ),
      ],
    );
    expect(
      find.text(
        'Your sky is off. Turn it on to look for new and changing sources '
        'in each frame.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the one-time notice deletes only after a confirmation', (
    tester,
  ) async {
    final db = mockDatabase();
    addTearDown(db.close);
    final atlas = _RecordingAtlas(db);
    await pump(
      tester,
      Builder(
        builder: (context) => Center(
          child: SkotiqButton(
            label: 'open',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const YourSkyOffNoticeDialog(bytes: 7800000000),
            ),
          ),
        ),
      ),
      extra: [
        databaseProvider.overrideWithValue(db),
        skyAtlasServiceProvider.overrideWithValue(atlas),
      ],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
        find.textContaining('holds 7.3 GiB and has been kept'), findsOneWidget);

    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Your sky data?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(atlas.deletes, 0);

    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(atlas.deletes, 1);
    expect(
      await SettingsDao(db).getSetting(skyAtlasOffNoticeKey),
      'shown',
    );
  });

  test('the cost text names the size limit', () {
    expect(yourSkyCostText(limitGb: 40), contains('40 GiB'));
    expect(yourSkyCostText(limitGb: 0), contains('no size limit'));
  });
}
