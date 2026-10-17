import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/science_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

Finder _fieldInRow(String title) {
  final row = find.ancestor(
    of: find.text(title),
    matching: find.byType(SettingRow),
  );
  return find.descendant(of: row, matching: find.byType(TextField));
}

Future<void> _blurAndPump(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, String>{});
  });

  testWidgets('TNS numeric IDs reject malformed text instead of saving zero',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const ScienceSettingsPage(),
      extraOverrides: [
        secretsStoreProvider.overrideWithValue(
          SecretsStore(InMemorySecureKeyValueStore()),
        ),
      ],
    );

    await tester.enterText(_fieldInRow('Bot id'), 'not-a-number');
    await _blurAndPump(tester);

    expect(find.text('Enter a positive whole-number ID'), findsOneWidget);
    expect(
      handle.container.read(scienceSettingsProvider).value!.tnsBotId,
      0,
    );

    await tester.enterText(_fieldInRow('Bot id'), '12345');
    await _blurAndPump(tester);
    expect(find.text('Enter a positive whole-number ID'), findsNothing);
    expect(
      handle.container.read(scienceSettingsProvider).value!.tnsBotId,
      12345,
    );
  });

  testWidgets('camera values expose invalid input and clamp visible text',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const ScienceSettingsPage(),
      extraOverrides: [
        secretsStoreProvider.overrideWithValue(
          SecretsStore(InMemorySecureKeyValueStore()),
        ),
      ],
    );

    final field = _fieldInRow('Saturation level (ADU)');
    await tester.enterText(field, 'invalid');
    await _blurAndPump(tester);
    expect(find.text('Enter a number from 255.0 to 65535.0'), findsOneWidget);
    expect(
      await handle.database.settingsDao.getSetting(
        'science.camera.saturation_adu',
      ),
      isNull,
    );

    await tester.enterText(field, '100000');
    await _blurAndPump(tester);
    expect(find.text('Enter a number from 255.0 to 65535.0'), findsNothing);
    expect(
      await handle.database.settingsDao.getSetting(
        'science.camera.saturation_adu',
      ),
      '65535',
    );
    expect(tester.widget<TextField>(field).controller!.text, '65535');
  });

  testWidgets('MPC code rejects punctuation rather than silently ignoring it',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const ScienceSettingsPage(),
      extraOverrides: [
        secretsStoreProvider.overrideWithValue(
          SecretsStore(InMemorySecureKeyValueStore()),
        ),
      ],
    );

    await tester.enterText(_fieldInRow('MPC observatory code'), 'A!1');
    await _blurAndPump(tester);

    expect(
      find.text('MPC codes must be exactly 3 letters or digits'),
      findsOneWidget,
    );
    expect(
      handle.container.read(scienceSettingsProvider).value!.mpcObservatoryCode,
      isEmpty,
    );
  });

  testWidgets('camera and catalog controls use the imaging host remotely',
      (tester) async {
    final backend = _MockNetworkBackend();
    final hostSettings = <String, String>{
      PhotometricCatalogService.onlineEnabledSettingKey: 'true',
      ScienceCameraAutoConfig.autoManagedKey: 'true',
      ScienceCameraAutoConfig.saturationKey: '4095',
    };
    when(
      () => backend.getScienceSettings(),
    ).thenAnswer((_) async => Map.of(hostSettings));
    when(() => backend.updateScienceSettings(any()))
        .thenAnswer((invocation) async {
      hostSettings.addAll(
        invocation.positionalArguments.single as Map<String, String>,
      );
    });

    final handle = await pumpAppScreen(
      tester,
      const ScienceSettingsPage(),
      registerTearDown: false,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        secretsStoreProvider.overrideWithValue(
          SecretsStore(InMemorySecureKeyValueStore()),
        ),
      ],
    );

    final saturation = _fieldInRow('Saturation level (ADU)');
    expect(tester.widget<TextField>(saturation).controller!.text, '4095');

    final catalogRow = find.ancestor(
      of: find.text('Deep catalog lookups (APASS DR9)'),
      matching: find.byType(SettingRow),
    );
    final catalogSwitch = find.descendant(
      of: catalogRow,
      matching: find.byType(SettingsSwitch),
    );
    await tester.ensureVisible(catalogSwitch);
    await tester.tap(catalogSwitch);
    await tester.pumpAndSettle();

    await tester.enterText(saturation, '16383');
    await _blurAndPump(tester);

    final writes = verify(
      () => backend.updateScienceSettings(captureAny()),
    ).captured.cast<Map<String, String>>();
    expect(
      writes.any(
        (write) =>
            write.length == 1 &&
            write[PhotometricCatalogService.onlineEnabledSettingKey] == 'false',
      ),
      isTrue,
    );
    expect(
      writes.any(
        (write) =>
            write[ScienceCameraAutoConfig.saturationKey] == '16383' &&
            write[ScienceCameraAutoConfig.autoManagedKey] == 'false',
      ),
      isTrue,
    );
    expect(
      await handle.database.settingsDao.getSetting(
        ScienceCameraAutoConfig.saturationKey,
      ),
      isNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    handle.container.dispose();
    await handle.database.close();
  });
}
