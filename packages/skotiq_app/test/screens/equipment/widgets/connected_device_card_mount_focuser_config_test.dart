// Widget tests for the ConnectedDevicecard mount + focuser "Configuration"
// dialogs' truthful validation/save behavior. The mount dialog holds no flip
// settings: every run arms its flip from Settings > Sequencer.
//
// Coercing malformed numeric input via `parse(...) ?? old` reports success
// while silently keeping the prior value, and sequential per-field writes land
// half a change. Both dialogs therefore validate before touching persistence
// (minutes 0..120; coefficient finite; backlash 0..10000), save through ONE
// batched AppSettingsNotifier call, and close only after the write resolves —
// showing an inline error and staying open otherwise.
//
// The harness wires a real in-memory settings store (via mockDatabase), so a
// save round-trips to `appSettingsProvider` state; "did zero work" is asserted
// as "state unchanged AND dialog still open", and a successful save as "state
// updated AND dialog closed".

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'device_action_finder.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';

import '../../../harness/harness.dart';

class _FailingSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async {
    throw StateError('settings database unavailable');
  }
}

Future<HarnessHandle> _pump(
    WidgetTester tester, DeviceType type) async {
  final handle = await pumpAppScreen(
    tester,
    ConnectedDeviceCard(type: type),
    settle: false,
  );
  // Resolve the settings provider so the dialog reads real values and post-save
  // state reads are deterministic.
  await handle.container.read(appSettingsProvider.future);
  _connect(handle, type);
  await tester.pump();
  return handle;
}

/// The configuration controls belong to a connected device.
void _connect(HarnessHandle handle, DeviceType type) =>
    readDeviceConnectionNotifier(handle.container, type)
      ..setConnecting('test-${type.name}')
      ..setConnected();

Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(skotiqIconButton('Settings'));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(find.text('Save'));
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<void> _waitForDialogToClose(
  WidgetTester tester,
  String title,
) async {
  for (var i = 0; i < 30 && find.text(title).evaluate().isNotEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Mount configuration', () {
    testWidgets(
        'holds no flip switch or minutes of its own and points to the '
        "run's meridian flip settings", (tester) async {
      final handle = await _pump(tester, DeviceType.mount);
      await _openDialog(tester);

      expect(find.text('Mount configuration'), findsOneWidget);
      expect(find.text('Auto meridian flip'), findsNothing);
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(
        find.textContaining('Settings > Sequencer > Meridian flip'),
        findsOneWidget,
      );
      expect(find.text('Open meridian flip settings'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await _waitForDialogToClose(tester, 'Mount configuration');
      expect(find.text('Mount configuration'), findsNothing);

      // A connected mount polls its position; let go of it before teardown.
      readDeviceConnectionNotifier(handle.container, DeviceType.mount)
          .setDisconnected();
      await tester.pump();
    });
  });

  group('Focuser configuration', () {
    // Field order in the dialog: [0] coefficient, [1] backlash.
    Finder coeffField() => find.byType(TextField).at(0);
    Finder backlashField() => find.byType(TextField).at(1);

    testWidgets('settings failure does not open a default-valued editor',
        (tester) async {
      final handle = await pumpAppScreen(
        tester,
        const ConnectedDeviceCard(type: DeviceType.focuser),
        extraOverrides: [
          appSettingsProvider.overrideWith(_FailingSettingsNotifier.new),
        ],
        settle: false,
      );
      _connect(handle, DeviceType.focuser);
      await tester.pump();

      await _openDialog(tester);

      expect(find.text('Focuser configuration'), findsNothing);
      expect(
        find.textContaining('Could not load focuser settings'),
        findsOneWidget,
      );
    });

    testWidgets('malformed coefficient does zero work and stays open',
        (tester) async {
      final handle = await _pump(tester, DeviceType.focuser);
      final before = handle.container
          .read(appSettingsProvider)
          .requireValue
          .tempCoefficient;

      await _openDialog(tester);
      await tester.enterText(coeffField(), 'abc');
      await _tapSave(tester);

      expect(find.text('Focuser configuration'), findsOneWidget);
      expect(
        handle.container.read(appSettingsProvider).requireValue.tempCoefficient,
        before,
      );
    });

    testWidgets('NaN coefficient is rejected and stays open', (tester) async {
      final handle = await _pump(tester, DeviceType.focuser);
      final before = handle.container
          .read(appSettingsProvider)
          .requireValue
          .tempCoefficient;

      await _openDialog(tester);
      await tester.enterText(coeffField(), 'NaN');
      await _tapSave(tester);

      expect(find.text('Focuser configuration'), findsOneWidget);
      expect(
        handle.container.read(appSettingsProvider).requireValue.tempCoefficient,
        before,
      );
    });

    testWidgets('Infinity coefficient is rejected and stays open',
        (tester) async {
      await _pump(tester, DeviceType.focuser);

      await _openDialog(tester);
      await tester.enterText(coeffField(), 'Infinity');
      await _tapSave(tester);

      expect(find.text('Focuser configuration'), findsOneWidget);
    });

    testWidgets('out-of-range backlash (10001) is rejected and stays open',
        (tester) async {
      final handle = await _pump(tester, DeviceType.focuser);
      final before = handle.container
          .read(appSettingsProvider)
          .requireValue
          .afBacklashIn;

      await _openDialog(tester);
      await tester.enterText(coeffField(), '2.0');
      await tester.enterText(backlashField(), '10001');
      await _tapSave(tester);

      expect(find.text('Focuser configuration'), findsOneWidget);
      expect(
        handle.container
            .read(appSettingsProvider)
            .requireValue
            .afBacklashIn,
        before,
      );
    });

    testWidgets('boundary values (coeff 0, backlash 10000) save and close',
        (tester) async {
      final handle = await _pump(tester, DeviceType.focuser);

      await _openDialog(tester);
      await tester.enterText(coeffField(), '0');
      await tester.enterText(backlashField(), '10000');
      await _tapSave(tester);
      await _waitForDialogToClose(tester, 'Focuser configuration');

      expect(find.text('Focuser configuration'), findsNothing);
      final state = handle.container.read(appSettingsProvider).requireValue;
      expect(state.tempCoefficient, 0);
      expect(state.afBacklashIn, 10000);
    });
  });
}
