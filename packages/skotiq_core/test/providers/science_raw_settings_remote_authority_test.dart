import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwitchableBackendNotifier extends BackendNotifier {
  _SwitchableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(<String, String>{});
  });

  test('raw science settings read and write the imaging host', () async {
    final backend = _MockNetworkBackend();
    when(() => backend.getScienceSettings()).thenAnswer(
      (_) async => {
        PhotometricCatalogService.onlineEnabledSettingKey: 'false',
        ScienceCameraAutoConfig.saturationKey: '4095',
      },
    );
    when(() => backend.updateScienceSettings(any())).thenAnswer((_) async {});

    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _SwitchableBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    final settings = await container.read(scienceRawSettingsProvider.future);
    expect(
      settings[PhotometricCatalogService.onlineEnabledSettingKey],
      'false',
    );
    expect(settings[ScienceCameraAutoConfig.saturationKey], '4095');

    final actions = container.read(scienceRawSettingsActionsProvider);
    await actions.setOnlineCatalogEnabled(true);
    await actions.setManualCameraValue(
      ScienceCameraAutoConfig.saturationKey,
      '16383',
    );

    final writes = verify(
      () => backend.updateScienceSettings(captureAny()),
    ).captured.cast<Map<String, String>>();
    expect(writes[0], {
      PhotometricCatalogService.onlineEnabledSettingKey: 'true',
    });
    expect(writes[1], {
      ScienceCameraAutoConfig.saturationKey: '16383',
      ScienceCameraAutoConfig.autoManagedKey: 'false',
    });
  });

  test('an in-flight action keeps the authority it was created for', () async {
    final backend = _MockNetworkBackend();
    final replacementBackend = _MockNetworkBackend();
    when(() => backend.updateScienceSettings(any())).thenAnswer((_) async {});
    late _SwitchableBackendNotifier backendNotifier;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) {
          backendNotifier = _SwitchableBackendNotifier(ref, backend);
          return backendNotifier;
        }),
      ],
    );
    addTearDown(container.dispose);

    final actions = container.read(scienceRawSettingsActionsProvider);
    backendNotifier.switchTo(replacementBackend);
    await actions.setOnlineCatalogEnabled(false);

    verify(
      () => backend.updateScienceSettings({
        PhotometricCatalogService.onlineEnabledSettingKey: 'false',
      }),
    ).called(1);
    verifyNever(() => replacementBackend.updateScienceSettings(any()));
  });

  test('typed science settings reload when remote authority changes', () async {
    final firstBackend = _MockNetworkBackend();
    final secondBackend = _MockNetworkBackend();
    when(
      () => firstBackend.getScienceSettings(),
    ).thenAnswer((_) async => {'science.feature.moving_objects': 'false'});
    when(
      () => secondBackend.getScienceSettings(),
    ).thenAnswer((_) async => {'science.feature.moving_objects': 'true'});
    late _SwitchableBackendNotifier backendNotifier;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) {
          backendNotifier = _SwitchableBackendNotifier(ref, firstBackend);
          return backendNotifier;
        }),
      ],
    );
    addTearDown(container.dispose);

    expect(
      (await container.read(
        scienceSettingsProvider.future,
      )).movingObjectsEnabled,
      isFalse,
    );
    backendNotifier.switchTo(secondBackend);
    expect(
      (await container.read(
        scienceSettingsProvider.future,
      )).movingObjectsEnabled,
      isTrue,
    );
  });

  test('manual camera writes reject unrelated science keys', () async {
    final backend = _MockNetworkBackend();
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _SwitchableBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);

    final actions = container.read(scienceRawSettingsActionsProvider);
    await expectLater(
      actions.setManualCameraValue('science.camera.typo', '12'),
      throwsArgumentError,
    );
    verifyNever(() => backend.updateScienceSettings(any()));
  });
}
