// Regressions for two false statements on Settings › Remote Access.
//
//  1. The page promised "Localhost stays frictionless for this machine, while
//     non-local clients must pair before they can control the app", and the
//     "Open on this computer" card said to use the local link "to confirm the
//     dashboard is working before sharing it elsewhere". There is no loopback
//     branch in the auth middleware: from 127.0.0.1, /api/status,
//     /api/images/recent and /api/auth/csrf all return the same 401 they return
//     to a LAN address, so an operator following that copy sees a dead page and
//     concludes the server is broken.
//  2. Connection details showed "Active Viewers", which is fed only from the
//     co-imaging collaboration manager's viewer list — it read 0 with a paired
//     client holding an authenticated /events WebSocket open.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/pairing_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/remote_access_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this._initial);
  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

class _StubPairingNotifier extends PairingNotifier {
  _StubPairingNotifier() {
    state = PairingState();
  }
}

/// Pins the seeded server state so the host machine's real interfaces cannot
/// overwrite it (see remote_access_tailscale_test.dart for the same pattern).
class _StubWebServerNotifier extends WebServerStateNotifier {
  _StubWebServerNotifier(WebServerState seed) {
    super.state = seed;
    _locked = true;
  }

  bool _locked = false;

  @override
  set state(WebServerState value) {
    if (_locked) return;
    super.state = value;
  }
}

const _authRequired = WebServerState(
  isRunning: true,
  actualPort: 8080,
  configuredPort: 8080,
  bindLocalOnly: false,
  requiresAuthentication: true,
  dashboardAvailable: true,
  serverFingerprint: 'abcdef0123456789abcdef0123456789',
  localIp: '192.168.1.50',
);

Future<void> _pumpRemoteAccess(
  WidgetTester tester, {
  WebServerState webState = _authRequired,
}) async {
  final database = mockDatabase();
  addTearDown(database.close);
  await pumpAppScreen(
    tester,
    const RemoteAccessSettings(),
    size: const Size(900, 1600),
    settle: false,
    database: database,
    extraOverrides: [
      appSettingsProvider.overrideWith(
        () => _StubAppSettingsNotifier(
          const AppSettingsState(webServerEnabled: true),
        ),
      ),
      pairingProvider.overrideWith((ref) => _StubPairingNotifier()),
      webServerStateProvider.overrideWith(
        (ref) => _StubWebServerNotifier(webState),
      ),
    ],
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the page never claims localhost is exempt from pairing',
      (tester) async {
    await _pumpRemoteAccess(tester);

    expect(
      find.textContaining('Localhost stays frictionless'),
      findsNothing,
      reason: 'the auth middleware has no loopback branch',
    );
    expect(
      find.textContaining('confirm the dashboard is working'),
      findsNothing,
      reason: 'an unpaired local dashboard loads no data, so it confirms '
          'nothing',
    );
    expect(
      find.textContaining('a browser on this computer is not exempt'),
      findsOneWidget,
    );
    expect(
      find.textContaining('until it does, the page loads but stays empty'),
      findsOneWidget,
    );
  });

  testWidgets('the collaboration count is not presented as remote clients',
      (tester) async {
    // Two clients on the wire, nobody co-imaging: the shape the live repro
    // produced (a paired phone holding /events, Active Viewers reading 0).
    await _pumpRemoteAccess(
      tester,
      webState: _authRequired.copyWith(
        connectedClients: 2,
        activeViewers: 0,
      ),
    );

    // Connection details is collapsed by default.
    await tester.tap(find.textContaining('Connection details'));
    await tester.pumpAndSettle();

    final activeViewers = find.ancestor(
      of: find.text('Active Viewers'),
      matching: find.byType(Row),
    );
    expect(activeViewers, findsWidgets);
    expect(
      find.descendant(of: activeViewers.first, matching: find.text('2')),
      findsOneWidget,
      reason: 'Active Viewers must count the attached remote clients',
    );

    final coImaging = find.ancestor(
      of: find.text('Co-imaging viewers'),
      matching: find.byType(Row),
    );
    expect(
      find.descendant(of: coImaging.first, matching: find.text('0')),
      findsOneWidget,
      reason: 'the collaboration count keeps its own labelled row',
    );
  });

  group('copy contract', () {
    test('an open server does not promise pairing it will not ask for', () {
      final body = describeRemoteAccessPairing(requiresAuthentication: false);
      expect(body, contains('not required'));
      expect(body, isNot(contains('frictionless')));
    });

    test('an authenticated server says the local browser pairs too', () {
      final body = describeRemoteAccessPairing(requiresAuthentication: true);
      expect(body, contains('not exempt'));
      expect(
        describeLocalDashboardAction(requiresAuthentication: true),
        contains('pairs like any other client'),
      );
    });
  });
}
