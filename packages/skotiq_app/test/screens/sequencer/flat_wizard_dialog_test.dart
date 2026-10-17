import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/flat_wizard_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _ConnectedCameraNotifier extends CameraStateNotifier {
  _ConnectedCameraNotifier(super.ref) {
    state = const CameraStateSnapshot(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'camera-1',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'uses a percentage target and refuses multi-filter calibration without '
    'a connected wheel',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          cameraStateProvider.overrideWith(_ConnectedCameraNotifier.new),
          profileFiltersProvider.overrideWithValue(
            const ['L', 'R', 'G', 'B'],
          ),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(currentSequenceProvider.notifier)
          .createSequence(name: 'Flat test');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: FlatWizardDialog()),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.textContaining('50% · camera range not detected'),
        findsOneWidget,
        reason: 'the UI must not present an absolute 16-bit target as fact',
      );

      await tester.tap(find.widgetWithText(FilterChip, 'R'));
      await tester.pump();
      final continueButton =
          find.widgetWithText(SkotiqButton, 'Continue').first;
      await tester.ensureVisible(continueButton);
      await tester.pump();
      await tester.tap(continueButton);
      await tester.pumpAndSettle();
      final calculateButton =
          find.widgetWithText(SkotiqButton, 'Calculate').first;
      await tester.ensureVisible(calculateButton);
      await tester.pump();
      await tester.tap(calculateButton);
      await tester.pump();

      expect(
        find.textContaining('Connect a filter wheel to calibrate multiple'),
        findsOneWidget,
      );
      expect(find.text('Calculating...'), findsNothing);
    },
  );

  testWidgets(
    'uses an editable manual filter name instead of inventing L',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          cameraStateProvider.overrideWith(_ConnectedCameraNotifier.new),
          profileFiltersProvider.overrideWithValue(const []),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(currentSequenceProvider.notifier)
          .createSequence(name: 'Manual flat test');

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: FlatWizardDialog()),
          ),
        ),
      );
      await tester.pump();

      expect(find.widgetWithText(FilterChip, 'L'), findsNothing);
      final manualFilter = find.widgetWithText(
        TextField,
        'Manual filter name',
      );
      expect(manualFilter, findsOneWidget);
      expect(find.text('Unfiltered'), findsOneWidget);

      await tester.enterText(manualFilter, 'Dual narrowband');
      await tester.pump();

      expect(find.text('Dual narrowband'), findsOneWidget);
      expect(find.text('Unfiltered'), findsNothing);
    },
  );
}
