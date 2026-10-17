import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/widgets/mosaic_wizard_dialog.dart';
import 'package:skotiq_app/screens/sequencer/widgets/quick_start_wizard_dialog.dart';
import 'package:skotiq_app/screens/sequencer/widgets/smart_night_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

Future<void> _expectClosesOnHostSwitch(
  WidgetTester tester, {
  required Widget dialog,
  required String dialogTitle,
  required _MockNetworkBackend hostA,
  required _MockNetworkBackend hostB,
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
  await tester.pumpAndSettle();
  expect(find.text(dialogTitle), findsOneWidget);

  notifier.switchTo(hostB);
  await tester.pumpAndSettle();

  expect(find.text(dialogTitle), findsNothing);
  expect(find.text('Open wizard'), findsOneWidget);
}

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
}
