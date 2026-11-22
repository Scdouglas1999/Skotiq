// A device card marks what the read-only connect check could not verify,
// with the fields on tap, and shows no mark for a device it verified.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../../harness/harness.dart';

const _kDeviceId = 'simulator:rotator:0';

class _ConnectedRotatorNotifier extends RotatorStateNotifier {
  _ConnectedRotatorNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const RotatorState(
      connectionState: DeviceConnectionState.connected,
      deviceId: _kDeviceId,
      deviceName: 'Simulated Rotator',
      position: 0,
    );
  }
}

class _Fields extends UnverifiedDeviceFields {
  _Fields(this._initial);
  final Map<String, List<String>> _initial;

  @override
  Map<String, List<String>> build() => _initial;
}

Future<void> _pump(
    WidgetTester tester, Map<String, List<String>> fields) async {
  await pumpAppScreen(
    tester,
    const ConnectedDeviceCard(type: DeviceType.rotator),
    backend: mockBackend(),
    extraOverrides: [
      rotatorStateProvider.overrideWith(_ConnectedRotatorNotifier.new),
      equipmentRotatorCapabilitiesProvider(
        _kDeviceId,
      ).overrideWith((ref) async => null),
      unverifiedDeviceFieldsProvider.overrideWith(() => _Fields(fields)),
    ],
    settle: false,
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  testWidgets('an unverified position is marked, with the fields on tap', (
    tester,
  ) async {
    await _pump(tester, {
      _kDeviceId: ['position'],
    });

    final mark = find.bySemanticsLabel('Not verified at connect');
    expect(mark, findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);

    await tester.tap(mark);
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.textContaining('Not verified at connect: position.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a verified device has no mark', (tester) async {
    await _pump(tester, {
      'simulator:focuser:0': ['position'],
    });
    expect(find.bySemanticsLabel('Not verified at connect'), findsNothing);
  });
}
