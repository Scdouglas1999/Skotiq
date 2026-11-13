import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mosaic_wizard_dialog.dart';
import 'package:skotiq_app/screens/sequencer/widgets/quick_start_wizard_dialog.dart';
import 'package:skotiq_app/screens/sequencer/widgets/smart_night_dialog.dart';
import 'package:skotiq_astro/skotiq_astro.dart' as planetarium;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

/// Pumps a button that opens [dialog] under [hostA] and returns the notifier
/// that switches hosts.
Future<_SwappableBackendNotifier> _pumpLauncher(
  WidgetTester tester, {
  required Widget dialog,
  required _MockNetworkBackend hostA,
  List<Override> overrides = const [],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1400, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  late _SwappableBackendNotifier notifier;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider.overrideWith((ref) {
          notifier = _SwappableBackendNotifier(ref, hostA);
          return notifier;
        }),
        profileFiltersProvider.overrideWithValue(const []),
        smartNightExposureContextProvider.overrideWith((ref) async => null),
        ...overrides,
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => dialog,
              ),
              child: const Text('Open wizard'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('Open wizard'));
  await tester.pump();
  return notifier;
}

Future<void> _expectClosesOnHostSwitch(
  WidgetTester tester, {
  required Widget dialog,
  required String dialogTitle,
  required _MockNetworkBackend hostA,
  required _MockNetworkBackend hostB,
}) async {
  final notifier = await _pumpLauncher(tester, dialog: dialog, hostA: hostA);
  await tester.pumpAndSettle();
  expect(find.text(dialogTitle), findsOneWidget);

  notifier.switchTo(hostB);
  await tester.pumpAndSettle();

  expect(find.text(dialogTitle), findsNothing);
  expect(find.text('Open wizard'), findsOneWidget);
  expect(find.byType(SnackBar), findsNothing);
}

class _PendingSettingsNotifier extends AppSettingsNotifier {
  _PendingSettingsNotifier(this._settings);

  final Future<AppSettingsState> _settings;

  @override
  Future<AppSettingsState> build() => _settings;
}

const _testRig = EquipmentProfileModel(
  name: 'Test rig',
  focalLength: 600,
  aperture: 120,
  filterNames: ['L', 'R', 'G', 'B'],
);

const _tonight = [
  TargetSuggestion(
    targetId: 50,
    targetName: 'M51',
    raHours: 13.5,
    decDegrees: 47.2,
    totalScore: 90,
    visibility: planetarium.TargetVisibilityInfo(
      currentAltitude: 60,
      currentAzimuth: 180,
      transitAltitude: 70,
      airmass: 1.2,
      moonDistance: 90,
      hoursAboveMinAlt: 5,
    ),
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Mosaic wizard closes when the connected rig changes',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    when(hostA.hasCheckpoint).thenAnswer((_) async => false);

    await _expectClosesOnHostSwitch(
      tester,
      dialog: const MosaicWizardDialog(initialRa: 12, initialDec: 30),
      dialogTitle: 'Mosaic wizard',
      hostA: hostA,
      hostB: hostB,
    );
  });

  testWidgets('Quick Start wizard closes when the connected rig changes',
      (tester) async {
    await _expectClosesOnHostSwitch(
      tester,
      dialog: const QuickStartWizardDialog(),
      dialogTitle: 'Quick-Start Sequence Wizard',
      hostA: _MockNetworkBackend(),
      hostB: _MockNetworkBackend(),
    );
  });

  testWidgets('Smart Night wizard closes when the connected rig changes',
      (tester) async {
    await _expectClosesOnHostSwitch(
      tester,
      dialog: const SmartNightDialog(),
      dialogTitle: 'Smart Night — Plan Tonight',
      hostA: _MockNetworkBackend(),
      hostB: _MockNetworkBackend(),
    );
  });

  testWidgets(
      'an interrupted-mosaic probe the old host answers after a switch asks '
      'it nothing more', (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final hasCheckpoint = Completer<bool>();
    when(hostA.hasCheckpoint).thenAnswer((_) => hasCheckpoint.future);

    final notifier = await _pumpLauncher(
      tester,
      dialog: const MosaicWizardDialog(initialRa: 12, initialDec: 30),
      hostA: hostA,
    );
    await tester.pump();
    verify(hostA.hasCheckpoint).called(1);

    // The old host answers in the same turn as the switch, before the closed
    // dialog has left the tree.
    notifier.switchTo(hostB);
    hasCheckpoint.complete(true);
    await tester.pumpAndSettle();

    expect(find.text('Mosaic wizard'), findsNothing);
    verifyNever(hostA.getCheckpointInfo);
    verifyNever(hostB.getCheckpointInfo);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Quick Start settings that load after a switch start no further loads',
      (tester) async {
    final settings = Completer<AppSettingsState>();
    var exposureContextLoads = 0;

    final notifier = await _pumpLauncher(
      tester,
      dialog: const QuickStartWizardDialog(),
      hostA: _MockNetworkBackend(),
      overrides: [
        inMemoryDatabaseOverride(),
        appSettingsProvider
            .overrideWith(() => _PendingSettingsNotifier(settings.future)),
        equipmentProfilesProvider.overrideWith(
          () => _FixedProfilesNotifier(),
        ),
        smartNightExposureContextProvider.overrideWith((ref) async {
          exposureContextLoads++;
          return null;
        }),
      ],
    );
    await tester.pump();
    expect(find.text('Quick-Start Sequence Wizard'), findsOneWidget);

    notifier.switchTo(_MockNetworkBackend());
    settings.complete(const AppSettingsState());
    await tester.pumpAndSettle();

    expect(find.text('Quick-Start Sequence Wizard'), findsNothing);
    expect(exposureContextLoads, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a Smart Night preview the old host feeds after a switch goes no further',
      (tester) async {
    final exposureContext = Completer<SmartNightExposureContext?>();
    var sensorSpecLoads = 0;

    final notifier = await _pumpLauncher(
      tester,
      dialog: const SmartNightDialog(),
      hostA: _MockNetworkBackend(),
      overrides: [
        inMemoryDatabaseOverride(),
        appSettingsProvider.overrideWith(
          () => _PendingSettingsNotifier(Future.value(const AppSettingsState())),
        ),
        appObserverLocationProvider.overrideWithValue(
          const LocationSettings(latitude: 40, longitude: -75),
        ),
        activeEquipmentProfileProvider.overrideWithValue(_testRig),
        tonightSuggestionsProvider.overrideWith((ref) async => _tonight),
        smartNightExposureContextProvider
            .overrideWith((ref) => exposureContext.future),
        activeCameraSensorSpecsProvider.overrideWith((ref) async {
          sensorSpecLoads++;
          return ResolvedCameraSensorSpecs.none;
        }),
      ],
    );
    await tester.pumpAndSettle();
    for (final step in ['2. Equipment', '3. Targets', '4. Strategy']) {
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text(step), findsOneWidget);
    }
    await tester.tap(find.text('Next'));
    await tester.pump();

    notifier.switchTo(_MockNetworkBackend());
    exposureContext.complete(null);
    await tester.pumpAndSettle();

    expect(find.text('Smart Night — Plan Tonight'), findsNothing);
    expect(sensorSpecLoads, 0);
    expect(tester.takeException(), isNull);
  });
}

class _FixedProfilesNotifier extends EquipmentProfilesNotifier {
  @override
  Future<EquipmentProfilesState> build() async =>
      const EquipmentProfilesState(
        profiles: [_testRig],
        activeProfile: _testRig,
      );
}
