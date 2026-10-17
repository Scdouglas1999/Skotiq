// About > System information carries every fact a support conversation opens
// with — build number, where the data lives, what schema it is on, not just
// Platform / OS Version / Dart Version — and the block copies in one action, so
// none of it has to be retyped into a bug report.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/about_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

Future<void> _pumpAbout(
  WidgetTester tester, {
  required List<SupportFact> facts,
  String? dataFolder,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 2000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inMemoryDatabaseOverride(),
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '6.1.0', buildNumber: 25),
        ),
        systemInformationProvider.overrideWithValue(facts),
        skotiqDataFolderProvider.overrideWith((ref) async => dataFolder),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: AboutSettings()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const facts = [
    SupportFact('Skotiq', '6.1.0 (build 25)'),
    SupportFact('Platform', 'linux'),
    SupportFact('Database schema', '57'),
  ];
  const dataFolder = '/home/observer/.local/share/skotiq';

  testWidgets('the block names the build, the schema and the data folder',
      (tester) async {
    await _pumpAbout(tester, facts: facts, dataFolder: dataFolder);

    expect(find.text('System information'), findsOneWidget);
    expect(find.text('6.1.0 (build 25)'), findsWidgets);
    expect(find.text('Database schema'), findsOneWidget);
    expect(find.text('57'), findsOneWidget);
    expect(
      find.text('/home/observer/.local/share/skotiq'),
      findsOneWidget,
    );
  });

  testWidgets('Copy puts the whole block on the clipboard', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await _pumpAbout(tester, facts: facts, dataFolder: dataFolder);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Copy'));
    await tester.pumpAndSettle();

    expect(copied, hasLength(1));
    expect(copied.single, contains('Skotiq: 6.1.0 (build 25)'));
    expect(copied.single, contains('Database schema: 57'));
    expect(
      copied.single,
      contains('Data folder: /home/observer/.local/share/skotiq'),
    );
  });

  test('the default collector reports the build number and the host', () {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '6.1.0', buildNumber: 25),
        ),
      ],
    );
    addTearDown(container.dispose);

    final byLabel = {
      for (final f in container.read(systemInformationProvider))
        f.label: f.value,
    };

    expect(byLabel['Skotiq'], '6.1.0 (build 25)');
    expect(byLabel['Platform'], isNotNull);
    expect(byLabel['Connected to'], isNotNull);
  });
}
