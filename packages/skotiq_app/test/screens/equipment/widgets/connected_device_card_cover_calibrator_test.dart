import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'device_action_finder.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../harness/harness.dart';

class _CoverNotifier extends CoverCalibratorStateNotifier {
  _CoverNotifier(super.ref) {
    state = const CoverCalibratorState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'cover-1',
      deviceName: 'Test Cover',
    );
  }
}

Future<HarnessHandle> pumpCover(
  WidgetTester tester, {
  required CoverCalibratorCapabilitySnapshot snapshot,
  MockBackend? backend,
}) {
  return pumpAppScreen(
    tester,
    const ConnectedDeviceCard(type: ConnectedDeviceType.coverCalibrator),
    backend: backend,
    extraOverrides: [
      coverCalibratorStateProvider.overrideWith(_CoverNotifier.new),
      coverCalibratorCapabilityFetcherProvider.overrideWithValue(
        (_) async => snapshot,
      ),
    ],
  );
}

void main() {
  testWidgets('cover-only device exposes no fabricated light controls',
      (tester) async {
    await pumpCover(
      tester,
      snapshot: const CoverCalibratorCapabilitySnapshot(
        coverPresent: true,
        calibratorPresent: false,
        coverStatus: CoverStatus.closed,
        maxBrightness: 0,
      ),
    );

    await expectDeviceAction(tester, 'Open cover', enabled: true);
    expect(find.text('Light on'), findsNothing);
    expect(skotiqIconButton('Settings'), findsNothing);
  });

  testWidgets('unknown cover state is visible but cannot guess a direction',
      (tester) async {
    await pumpCover(
      tester,
      snapshot: const CoverCalibratorCapabilitySnapshot(
        coverPresent: true,
        calibratorPresent: false,
        coverStatus: CoverStatus.unknown,
        maxBrightness: 0,
      ),
    );

    await expectDeviceAction(tester, 'Cover unavailable', enabled: false);
  });

  testWidgets('first light-on uses a safe midpoint and is single-flight',
      (tester) async {
    final backend = mockBackend();
    final pending = Completer<void>();
    when(() => backend.calibratorOn('cover-1', 50))
        .thenAnswer((_) => pending.future);

    await pumpCover(
      tester,
      backend: backend,
      snapshot: const CoverCalibratorCapabilitySnapshot(
        coverPresent: false,
        calibratorPresent: true,
        calibratorStatus: CalibratorStatus.off,
        brightness: 0,
        maxBrightness: 100,
      ),
    );

    await tester.tap(find.text('Light on'));
    await tester.pump();
    await tester.tap(find.text('Light on'));
    await tester.pump();

    verify(() => backend.calibratorOn('cover-1', 50)).called(1);

    pending.complete();
    await tester.pumpAndSettle();
  });
}
