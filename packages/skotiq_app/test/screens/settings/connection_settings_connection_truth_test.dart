// Focused tests for Settings → Connection (ConnectionSettings) covering the
// connection-truth fixes:
//
//   * a live connection state (not merely `backend is NetworkBackend`) drives
//     the status chip, so a mid-handshake session reads "Connecting...",
//   * the Discovery section exposes a reachable INDI server host/port entry
//     that opens IndiServerDialog (off-Windows),
//   * Connect opens the app's one connect flow (the desktop's link dialog,
//     the phone's connection screen) instead of a dialog of its own.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/indi_server_dialog.dart';
import 'package:skotiq_app/screens/connection/rig_connect_entry.dart';
import 'package:skotiq_app/screens/settings/widgets/connection_settings.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';
import 'package:skotiq_core/models.dart';

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

  // The page said "Saved on this device only" over discovery switches that
  // a linked client reads from and writes to the imaging host.
  testWidgets('a linked client labels each group by where it is stored',
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
      size: const Size(1280, 1600),
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

    double top(Finder finder) => tester.getTopLeft(finder).dy;
    final local = find.textContaining('Saved on this device only');
    final host = find.textContaining('Saved on the imaging host (10.0.0.5)');
    expect(local, findsOneWidget);
    expect(host, findsOneWidget);
    expect(top(local), lessThan(top(find.text('SERVER STATUS'))));
    expect(top(find.text('SERVER STATUS')), lessThan(top(host)));
    expect(top(host), lessThan(top(find.text('DISCOVERY'))));
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

  testWidgets('Connect opens the app\'s one connect flow', (tester) async {
    var opened = 0;
    await pumpAppScreen(
      tester,
      const ConnectionSettings(),
      extraOverrides: [
        appSettingsProvider.overrideWith(
          () => _StubAppSettingsNotifier(const AppSettingsState()),
        ),
        openRigConnectProvider.overrideWith((ref) => (_) => opened++),
      ],
    );

    final openConnect = find.widgetWithText(SkotiqButton, 'Connect');
    await tester.ensureVisible(openConnect);
    await tester.tap(openConnect);
    await tester.pumpAndSettle();

    expect(opened, 1);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
