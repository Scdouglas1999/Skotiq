// Focused tests for Settings → Connection (ConnectionSettings) covering the
// connection-truth fixes:
//
//   * a live connection state (not merely `backend is NetworkBackend`) drives
//     the status chip, so a mid-handshake session reads "Connecting...",
//   * the Discovery section exposes a reachable INDI server host/port entry
//     that opens IndiServerDialog (off-Windows),
//   * the "Connect to Server" dialog validates its port, stays open on an
//     invalid entry, and seeds a neutral host rather than an unrelated
//     Alpaca/INDI device-protocol address.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/dialogs/indi_server_dialog.dart';
import 'package:skotiq_app/screens/settings/widgets/connection_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

class _FailingRefreshSettingsNotifier extends AppSettingsNotifier {
  int _buildCount = 0;

  @override
  Future<AppSettingsState> build() async {
    _buildCount++;
    if (_buildCount == 1) return const AppSettingsState();
    throw StateError('host settings unavailable');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'status reads "Connecting..." while the network backend is mid-handshake',
    (tester) async {
      final backend = NetworkBackend(
        serverHost: '10.0.0.5',
        serverPort: 8080,
        webSocketPort: 8080,
        autoConnectWebSocket: false,
      );
      addTearDown(backend.dispose);

      await pumpAppScreen(
        tester,
        const ConnectionSettings(),
        extraOverrides: [
          appSettingsProvider.overrideWith(
            () => _StubAppSettingsNotifier(const AppSettingsState()),
          ),
          backendProvider.overrideWith(
            (ref) => TestBackendNotifier(ref, backend),
          ),
          networkBackendConnectionStateProvider.overrideWith(
            (ref) => Stream.value(BackendConnectionState.connecting),
          ),
        ],
      );

      expect(find.text('Connecting...'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
    },
  );

  testWidgets('status reads "Connected" only when the backend is live',
      (tester) async {
    final backend = NetworkBackend(
      serverHost: '10.0.0.5',
      serverPort: 8080,
      webSocketPort: 8080,
      autoConnectWebSocket: false,
    );
    addTearDown(backend.dispose);

    await pumpAppScreen(
      tester,
      const ConnectionSettings(),
      extraOverrides: [
        appSettingsProvider.overrideWith(
          () => _StubAppSettingsNotifier(const AppSettingsState()),
        ),
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, backend),
        ),
        networkBackendConnectionStateProvider.overrideWith(
          (ref) => Stream.value(BackendConnectionState.connected),
        ),
      ],
    );

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('Connecting...'), findsNothing);
  });

  testWidgets(
    'Discovery exposes an INDI Server Address entry that opens the dialog',
    (tester) async {
      await pumpAppScreen(
        tester,
        const ConnectionSettings(),
        extraOverrides: [
          appSettingsProvider.overrideWith(
            () => _StubAppSettingsNotifier(
              const AppSettingsState(
                indiServerHost: '10.0.0.9',
                indiServerPort: 7625,
              ),
            ),
          ),
        ],
      );

      final entry = find.text('INDI server address');
      expect(entry, findsOneWidget);
      // Subtitle reflects the configured address.
      expect(find.textContaining('10.0.0.9:7625'), findsOneWidget);

      // Discovery now has two Configure buttons (INDI, then Alpaca); the
      // INDI row is declared first, so `.first` is the one under test.
      final configure = find.widgetWithText(SkotiqButton, 'Configure').first;
      await tester.ensureVisible(configure);
      await tester.tap(configure);
      await tester.pumpAndSettle();

      expect(find.byType(IndiServerDialog), findsOneWidget);
      expect(find.text('INDI server'), findsOneWidget);
    },
    skip: Platform.isWindows,
  );

  testWidgets('host settings refresh waits for and reports a failed reload',
      (tester) async {
    final backend = NetworkBackend(
      serverHost: '10.0.0.5',
      serverPort: 8080,
      webSocketPort: 8080,
      autoConnectWebSocket: false,
    );
    addTearDown(backend.dispose);

    await pumpAppScreen(
      tester,
      const ConnectionSettings(),
      extraOverrides: [
        appSettingsProvider.overrideWith(_FailingRefreshSettingsNotifier.new),
        backendProvider.overrideWith(
          (ref) => TestBackendNotifier(ref, backend),
        ),
        networkBackendConnectionStateProvider.overrideWith(
          (ref) => Stream.value(BackendConnectionState.connected),
        ),
      ],
    );

    // Reveal it first: Discovery gained the Alpaca address row, so Remote
    // Features can start below the fold at the harness surface size.
    final refresh = find.byTooltip('Refresh host settings');
    await tester.ensureVisible(refresh);
    await tester.pump();
    await tester.tap(refresh);
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('host settings unavailable'), findsOneWidget);
    expect(find.text('Host settings refreshed'), findsNothing);
    // The control is a SkotiqIconButton now, not a Material IconButton
    // wrapping one, so its own onPressed is what says the retry is live.
    final button = tester.widget<SkotiqIconButton>(
      find.ancestor(
        of: find.byTooltip('Refresh host settings'),
        matching: find.byType(SkotiqIconButton),
      ),
    );
    expect(button.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Connect to Server dialog seeds a neutral host and rejects a bad port',
    (tester) async {
      final handle = await pumpAppScreen(
        tester,
        const ConnectionSettings(),
        extraOverrides: [
          appSettingsProvider.overrideWith(
            () => _StubAppSettingsNotifier(
              // Distinctive device-protocol addresses that must NOT leak into
              // the Skotiq-server host field.
              const AppSettingsState(
                alpacaServerHost: 'alpaca.box',
                indiServerHost: 'indi.box',
              ),
            ),
          ),
        ],
      );

      final openConnect = find.widgetWithText(SkotiqButton, 'Connect');
      await tester.ensureVisible(openConnect);
      await tester.tap(openConnect);
      await tester.pumpAndSettle();

      // Neutral default host — not conflated with Alpaca/INDI settings.
      final hostField = tester.widget<TextField>(
        find.byKey(const ValueKey('connect-host-field')),
      );
      expect(hostField.controller!.text, 'localhost');
      expect(hostField.controller!.text, isNot('alpaca.box'));
      expect(hostField.controller!.text, isNot('indi.box'));

      // An out-of-range port is rejected in place; the dialog stays open and
      // the backend is never swapped to a NetworkBackend.
      await tester.enterText(
        find.byKey(const ValueKey('connect-port-field')),
        '0',
      );
      final dialogConnect = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(SkotiqButton, 'Connect'),
      );
      await tester.tap(dialogConnect);
      await tester.pumpAndSettle();

      expect(find.text('Port must be between 1 and 65535.'), findsOneWidget);
      // Dialog stays open (its port field is still mounted).
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.byKey(const ValueKey('connect-port-field')),
        findsOneWidget,
      );
      expect(
        handle.container.read(backendProvider),
        isNot(isA<NetworkBackend>()),
        reason: 'A rejected port must not trigger a connect / backend swap.',
      );
    },
  );
}
