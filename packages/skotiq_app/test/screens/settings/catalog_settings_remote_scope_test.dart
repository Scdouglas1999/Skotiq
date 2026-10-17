// Live on a paired phone: Settings -> Catalogs reported HYG and OpenNGC as
// "Installed" by reading the PHONE's filesystem while the rig it was driving
// had none, so plate solving, target search, framing and annotation were dead
// on the machine that needs them and no card offered an install action.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/catalog_settings_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _PinnedBackendNotifier extends BackendNotifier {
  _PinnedBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

Future<void> _pump(WidgetTester tester, {SkotiqBackend? backend}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1000, 2400);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (backend != null)
          backendProvider
              .overrideWith((ref) => _PinnedBackendNotifier(ref, backend)),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: CatalogSettingsScreen(isMobile: true)),
      ),
    ),
  );
  for (var attempt = 0; attempt < 20; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    if (find.text('HYG Star Database').evaluate().isNotEmpty) return;
  }
  expect(find.text('HYG Star Database'), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory catalogDirectory;

  setUpAll(() async {
    catalogDirectory = await Directory.systemTemp.createTemp(
      'skotiq_catalog_scope_test_',
    );
    await CatalogManager.instance.initialize(catalogDirectory.path);
  });

  setUp(() async {
    await for (final entity in catalogDirectory.list()) {
      await entity.delete(recursive: true);
    }
    await File(CatalogManager.instance.starCatalogPath).writeAsString(
      'id,proper,ra,dec,mag\n1,Polaris,2.5,89.2,1.9\n',
    );
    await File(CatalogManager.instance.dsoCatalogPath).writeAsString(
      'Name,RA,Dec,V-Mag\nNGC224,00:42:44,+41:16:09,3.4\n',
    );
  });

  tearDownAll(() async {
    if (await catalogDirectory.exists()) {
      await catalogDirectory.delete(recursive: true);
    }
  });

  testWidgets(
    'a device install is never reported as installed on a rig that has none',
    (tester) async {
      final backend = _MockNetworkBackend();
      when(() => backend.getCatalogStatus()).thenAnswer(
        (_) async => const RemoteCatalogStatusResponse(
          catalogs: [
            RemoteCatalogStatus(name: 'stars', status: 'missing'),
            RemoteCatalogStatus(name: 'dso', status: 'missing'),
            RemoteCatalogStatus(name: 'annotation', status: 'missing'),
          ],
          totalBytes: 0,
          dataDir: '/var/lib/skotiq/catalogs',
        ),
      );
      await _pump(tester, backend: backend);

      expect(find.text('Installed'), findsNothing);
      expect(find.text('On this device'), findsWidgets);
      expect(find.text('Not on the rig'), findsWidgets);
      expect(
        find.textContaining('plate solving, target search'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(SkotiqButton, 'Manage rig catalogs'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the rig-installed case is reported as installed on the rig',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.getCatalogStatus()).thenAnswer(
      (_) async => const RemoteCatalogStatusResponse(
        catalogs: [
          RemoteCatalogStatus(name: 'stars', status: 'installed'),
          RemoteCatalogStatus(name: 'dso', status: 'installed'),
        ],
        totalBytes: 42,
        dataDir: '/var/lib/skotiq/catalogs',
      ),
    );
    await _pump(tester, backend: backend);

    // stars + dso are on the rig; the annotation catalog the rig did not list
    // is reported missing rather than inheriting the device's answer.
    expect(find.text('On the rig'), findsNWidgets(2));
    expect(find.text('Not on the rig'), findsOneWidget);
    expect(find.textContaining('plate solving, target search'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a local session still reports a plain install', (tester) async {
    await _pump(tester);

    expect(find.text('Installed'), findsWidgets);
    expect(find.text('Not on the rig'), findsNothing);
    expect(find.text('On this device'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
