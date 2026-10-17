// Settings → Connection must let the operator say WHERE the Alpaca server is.
//
// Shipped state: the page carried "Query Alpaca on startup / Include the
// configured Alpaca server in automatic startup discovery" with no address row
// anywhere, and `grep -rn setAlpacaServerHost packages/skotiq_app` returned
// nothing — so the address `unified_discovery_provider` consults was pinned to
// the stored default localhost:11111 for the life of the install, while the
// same page recommends Alpaca for cross-platform rigs that typically live on
// another machine on the LAN.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/connection_settings.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

class _MockDeviceService extends Mock implements DeviceService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the Alpaca address is shown and can be changed', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const ConnectionSettings(),
      size: const Size(1280, 1600),
      extraOverrides: [
        appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
      ],
    );
    await tester.pumpAndSettle();

    final row = find.text('Alpaca server address');
    expect(row, findsOneWidget);
    expect(
      find.textContaining('localhost:11111'),
      findsWidgets,
      reason: 'the row must show the address discovery will actually use',
    );

    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    // The Configure button belonging to the Alpaca row: INDI's row (present on
    // Linux/macOS) renders the same label above it.
    await tester.tap(find.text('Configure').last);
    await tester.pumpAndSettle();

    expect(find.text('Alpaca Server Configuration'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('alpaca-host-field')),
      '192.168.1.47',
    );
    await tester.enterText(
      find.byKey(const ValueKey('alpaca-port-field')),
      '32323',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final settings = handle.container.read(appSettingsProvider).requireValue;
    expect(settings.alpacaServerHost, '192.168.1.47');
    expect(settings.alpacaServerPort, 32323);
    // And the page now reports the address that was stored.
    expect(find.textContaining('192.168.1.47:32323'), findsWidgets);
  });

  testWidgets('a malformed port is refused rather than coerced', (
    tester,
  ) async {
    final handle = await pumpAppScreen(
      tester,
      const ConnectionSettings(),
      size: const Size(1280, 1600),
      extraOverrides: [
        appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
      ],
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Alpaca server address'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Configure').last);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('alpaca-port-field')),
      '99999',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Port must be between 1 and 65535.'), findsOneWidget);
    expect(
      handle.container.read(appSettingsProvider).requireValue.alpacaServerPort,
      11111,
    );
  });

  // Found live (coverage closeout, never-claimed cluster B). Test Connection
  // against a dead localhost:11111 printed:
  //
  //   No response on localhost:11111. SkotiqError.connectionFailed(
  //   deviceId: localhost:11111, reason: Failed to connect to Alpaca server: …)
  //
  // — the freezed union's DEBUG rendering, class name and field names and all,
  // shipped as product copy. And the verdict stayed on screen after the host
  // was retyped, so a failure report for localhost sat under a field reading
  // 192.168.1.50 with nothing marking it stale.
  testWidgets(
    'a failed probe names the cause, not the error object, and is dropped '
    'when the address changes',
    (tester) async {
      final service = _MockDeviceService();
      when(() => service.discoverAlpacaAtAddress(any(), any())).thenAnswer(
        (_) async => throw bridge.SkotiqError.connectionFailed(
          deviceId: 'localhost:11111',
          reason: 'Connection refused (os error 111)',
        ),
      );

      await pumpAppScreen(
        tester,
        const ConnectionSettings(),
        size: const Size(1280, 1600),
        extraOverrides: [
          appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
          deviceServiceProvider.overrideWithValue(service),
        ],
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Alpaca server address'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Configure').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Test Connection'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Connection refused (os error 111)'),
        findsOneWidget,
        reason: 'the operator needs the cause the server actually reported',
      );
      expect(
        find.textContaining('SkotiqError.'),
        findsNothing,
        reason: 'the Dart union type name is a stack-trace detail, not copy',
      );
      expect(find.textContaining('deviceId:'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey('alpaca-host-field')),
        '192.168.1.50',
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No response on'),
        findsNothing,
        reason: 'a verdict about localhost must not survive into a new address',
      );
    },
  );
}
