// A device whose connect failed keeps a card that names it and can try it
// again, from the card's Retry and from the troubleshooter's
// "Retry connection" alike.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _RecordingDeviceService extends DeviceService {
  _RecordingDeviceService(super.ref, super.backend);

  final List<(DeviceType, String)> connects = [];

  @override
  Future<void> connect(
    DeviceType type,
    String deviceId, {
    String? host,
    int? port,
  }) async {
    connects.add((type, deviceId));
  }
}

const _focuserId = 'sim_focuser_1';

Future<(ProviderContainer, _RecordingDeviceService)> _pumpFailedFocuser(
  WidgetTester tester,
) async {
  late _RecordingDeviceService service;
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      deviceServiceProvider.overrideWith((ref) {
        service = _RecordingDeviceService(ref, ref.watch(backendProvider));
        ref.onDispose(service.dispose);
        return service;
      }),
    ],
  );
  addTearDown(container.dispose);
  container.read(deviceServiceProvider);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
        supportedLocales: SkotiqLocalizations.supportedLocales,
        home: const Scaffold(
          body: SizedBox(
            width: 400,
            child: ConnectedDeviceCard(type: DeviceType.focuser),
          ),
        ),
      ),
    ),
  );

  container.read(focuserStateProvider.notifier)
    ..setConnecting(_focuserId, 'Simulated Focuser')
    ..connectFailed(
      Exception('Injected simulator fault: the driver reported a failure'),
    );
  await tester.pumpAndSettle();
  return (container, service);
}

void main() {
  testWidgets('a device that failed to connect is named and Retry connects it',
      (tester) async {
    final (container, service) = await _pumpFailedFocuser(tester);

    expect(
      container.read(focuserStateProvider).connectionState,
      DeviceConnectionState.error,
    );
    expect(find.text('Simulated Focuser'), findsOneWidget);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Retry'));
    await tester.pumpAndSettle();

    expect(service.connects, [(DeviceType.focuser, _focuserId)]);
  });

  testWidgets("the troubleshooter's Retry connection connects the device",
      (tester) async {
    final (_, service) = await _pumpFailedFocuser(tester);

    await tester.tap(find.text('Diagnose'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry connection'));
    await tester.pumpAndSettle();

    expect(service.connects, [(DeviceType.focuser, _focuserId)]);
  });
}
