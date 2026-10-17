import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/your_sky/region_detail_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockFfiBackend extends Mock implements FfiBackend {}

class _SwitchingBackendNotifier extends BackendNotifier {
  _SwitchingBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void replaceWith(SkotiqBackend backend) => state = backend;
}

SkyAtlasRegionRow _region() => SkyAtlasRegionRow(
      id: 42,
      name: 'M 31 core',
      kind: 'target',
      centerRaDeg: 10.68,
      centerDecDeg: 41.27,
      radiusDeg: 1.2,
      tileCount: 3,
      integrationSeconds: 900,
      createdAt: DateTime.utc(2026, 7, 14),
    );

({ProviderContainer container, _SwitchingBackendNotifier backendNotifier})
    _container({
  required SkotiqBackend backend,
  required YourSkyRegionExporter exporter,
  required YourSkyRegionShare share,
  required YourSkyReferenceStarter referenceStarter,
}) {
  late _SwitchingBackendNotifier backendNotifier;
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith((ref) {
        return backendNotifier = _SwitchingBackendNotifier(ref, backend);
      }),
      yourSkyRegionExporterProvider.overrideWithValue(exporter),
      yourSkyRegionShareProvider.overrideWithValue(share),
      yourSkyReferenceStarterProvider.overrideWithValue(referenceStarter),
    ],
  );
  container.read(backendProvider);
  return (container: container, backendNotifier: backendNotifier);
}

Widget _surface(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: RegionCutoutActions(region: _region()),
      ),
    ),
  );
}

void main() {
  testWidgets('host change unlocks Export and discards the old host completion',
      (tester) async {
    final first = Completer<RegionCutoutExport?>();
    final second = Completer<RegionCutoutExport?>();
    var exportCalls = 0;
    final sharedPaths = <String>[];
    final h = _container(
      backend: _MockFfiBackend(),
      exporter: (_) {
        exportCalls++;
        return exportCalls == 1 ? first.future : second.future;
      },
      share: (path, {required text}) async => sharedPaths.add(path),
      referenceStarter: (_) async {},
    );
    addTearDown(h.container.dispose);

    await tester.pumpWidget(_surface(h.container));
    await tester.tap(find.widgetWithText(SkotiqButton, 'Export'));
    await tester.pump();

    expect(exportCalls, 1);
    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Export'),
          )
          .onPressed,
      isNull,
    );

    h.backendNotifier.replaceWith(_MockFfiBackend());
    await tester.pump();

    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Export'),
          )
          .onPressed,
      isNotNull,
    );

    first.complete(null);
    await tester.pump();
    expect(find.text('No co-add to export yet.'), findsNothing);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Export'));
    await tester.pump();
    expect(exportCalls, 2);
    second.complete(const RegionCutoutExport(
      regionName: 'M 31 core',
      fitsPath: '/host-b/m31.fits',
      pngPath: '/host-b/m31.png',
    ));
    await tester.pump();

    expect(sharedPaths, ['/host-b/m31.png']);
  });

  testWidgets(
      'reference completion from the old host is silent and cannot relock the new action',
      (tester) async {
    final firstStart = Completer<void>();
    final secondStart = Completer<void>();
    var startCalls = 0;
    final h = _container(
      backend: _MockFfiBackend(),
      exporter: (_) async => const RegionCutoutExport(
        regionName: 'M 31 core',
        fitsPath: '/atlas/m31.fits',
        pngPath: '/atlas/m31.png',
      ),
      share: (path, {required text}) async {},
      referenceStarter: (_) {
        startCalls++;
        return startCalls == 1 ? firstStart.future : secondStart.future;
      },
    );
    addTearDown(h.container.dispose);

    await tester.pumpWidget(_surface(h.container));
    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Use as reference frame'),
    );
    await tester.pump();
    expect(startCalls, 1);

    h.backendNotifier.replaceWith(_MockFfiBackend());
    await tester.pump();
    firstStart.complete();
    await tester.pump();

    expect(find.textContaining('Armed live stacking'), findsNothing);
    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(
              SkotiqButton,
              'Use as reference frame',
            ),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(
      find.widgetWithText(SkotiqButton, 'Use as reference frame'),
    );
    await tester.pump();
    expect(startCalls, 2);
    secondStart.complete();
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining('Armed live stacking on M 31 core'),
      findsOneWidget,
    );
  });
}
