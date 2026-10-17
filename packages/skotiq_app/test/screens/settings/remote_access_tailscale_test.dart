// Widget tests for the Tailscale reachability panel inside
// [RemoteAccessSettings] (P4 — "Desktop QR guidance and docs").
//
// What these lock in (the behaviour contract a senior reviewer would want
// pinned, because each is a way the feature can silently regress into either
// a broken UX or — worse — advertising a host the phone can't reach):
//
//   1. reachable_renders_tailnet_host_not_lan — when the desktop has a live
//      tailnet address AND is bound beyond loopback, the panel surfaces the
//      `100.x` host and its bracket-correct URL, and never the LAN address.
//      The whole point of the feature is "connect from anywhere", so leaking
//      the LAN IP here would quietly defeat it.
//   2. not_detected_shows_alert_recheck_and_manual_field — with no tailnet
//      address the operator gets an actionable info alert (not a dead end):
//      a Re-check button and a manual host entry.
//   3. recheck_button_reresolves_without_dropping_state — tapping Re-check
//      replays the running parameters through the notifier so a fresh
//      interface scan runs while port/fingerprint/auth survive intact. A
//      regression that invalidated the provider would blank the panel.
//   4. manual_lan_host_is_rejected — typing a LAN/garbage host shows the
//      validation error and does NOT produce a QR. The fail-closed
//      TailnetDetector boundary must hold at the UI too.
//   5. manual_tailnet_host_builds_qr — typing a valid `100.x` host with an
//      active pairing code produces a QR whose payload round-trips through the
//      strict parser back to that exact tailnet host.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/pairing_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/remote_access_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../harness/harness.dart';

/// Locates the Tailscale panel's QR specifically (the screen also renders a
/// separate LAN pairing QR), keyed off the distinctive semantics label the
/// panel sets.
final Finder _tailscaleQrFinder = find.byWidgetPredicate(
  (w) =>
      w is QrImageView &&
      w.semanticsLabel.contains('Skotiq Tailscale pairing QR'),
);

/// Fixed-state [AppSettingsNotifier] so the panel renders the running-server
/// branch without touching the database / network backend.
class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this._initial);

  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

class _FailingSettingsDao extends SettingsDao {
  _FailingSettingsDao(super.db);

  @override
  Future<void> setSetting(String key, String value) async {
    throw StateError('write failed');
  }
}

/// Fixed-`pairingCode` pairing notifier.
///
/// Subclasses the production [PairingNotifier] (the provider is typed to it).
/// The base constructor kicks off a *lazy* Drift open + `loadPairedDevices`;
/// in a widget test `path_provider` is unavailable so that load fails and is
/// swallowed by the production try/catch, leaving only an `error` field set —
/// it never disturbs the `pairingCode` we seed here (copyWith preserves it).
class _StubPairingNotifier extends PairingNotifier {
  _StubPairingNotifier(String? pairingCode) {
    state = PairingState(pairingCode: pairingCode);
  }
}

/// Test double for [WebServerStateNotifier].
///
/// It MUST extend the production notifier because `webServerStateProvider`
/// is a `StateNotifierProvider<WebServerStateNotifier, …>` and the panel reads
/// `.notifier` with that concrete type for its Re-check call.
///
/// Two production behaviours are neutralised so the panel sees a deterministic
/// state instead of the host machine's real interfaces:
///   * the base constructor kicks off an async interface scan
///     (`_resolveLocalIp`) that would overwrite `localIp` / `tailscaleIp`. We
///     "lock" the seeded state — once locked, state writes are ignored — so the
///     late-arriving scan result can't clobber the fixture.
///   * [setRunning] is overridden to record the call and replay the params
///     synchronously (no rescan), which is exactly what the Re-check path needs
///     to assert against.
class _StubWebServerNotifier extends WebServerStateNotifier {
  _StubWebServerNotifier(WebServerState seed) {
    super.state = seed;
    _locked = true;
  }

  bool _locked = false;
  int setRunningCalls = 0;

  @override
  set state(WebServerState value) {
    if (_locked) {
      // Allow only the explicit setRunning replay below to mutate; ignore the
      // base class's async interface-scan write.
      return;
    }
    super.state = value;
  }

  @override
  void setRunning({
    required bool isRunning,
    required int actualPort,
    int? configuredPort,
    bool? bindLocalOnly,
    bool? requiresAuthentication,
    bool? dashboardAvailable,
    String? lastError,
    String? serverFingerprint,
  }) {
    setRunningCalls++;
    final next = state.copyWith(
      isRunning: isRunning,
      actualPort: actualPort,
      configuredPort: configuredPort,
      bindLocalOnly: bindLocalOnly,
      requiresAuthentication: requiresAuthentication,
      dashboardAvailable: dashboardAvailable,
      lastError: lastError,
      serverFingerprint: serverFingerprint,
    );
    final wasLocked = _locked;
    _locked = false;
    state = next;
    _locked = wasLocked;
  }
}

List<Override> _overrides({
  required WebServerState webState,
  required String? pairingCode,
  AppSettingsState settings = const AppSettingsState(webServerEnabled: true),
  void Function(_StubWebServerNotifier)? captureWeb,
}) {
  return [
    appSettingsProvider.overrideWith(
      () => _StubAppSettingsNotifier(settings),
    ),
    pairingProvider.overrideWith(
      (ref) => _StubPairingNotifier(pairingCode),
    ),
    webServerStateProvider.overrideWith((ref) {
      final notifier = _StubWebServerNotifier(webState);
      captureWeb?.call(notifier);
      return notifier;
    }),
  ];
}

const _runningTailnet = WebServerState(
  isRunning: true,
  actualPort: 8080,
  configuredPort: 8080,
  bindLocalOnly: false,
  requiresAuthentication: true,
  dashboardAvailable: true,
  serverFingerprint: 'abcdef0123456789abcdef0123456789',
  localIp: '192.168.1.50',
  tailscaleIp: '100.96.0.7',
  tailscaleReachable: true,
);

const _runningNoTailnet = WebServerState(
  isRunning: true,
  actualPort: 8080,
  configuredPort: 8080,
  bindLocalOnly: false,
  requiresAuthentication: true,
  dashboardAvailable: true,
  serverFingerprint: 'abcdef0123456789abcdef0123456789',
  localIp: '192.168.1.50',
  tailscaleIp: '',
  tailscaleReachable: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('failed port save restores the last confirmed value',
      (tester) async {
    final database = mockDatabase();
    addTearDown(database.close);
    await pumpAppScreen(
      tester,
      const RemoteAccessSettings(),
      size: const Size(900, 1400),
      database: database,
      registerTearDown: false,
      extraOverrides: [
        ..._overrides(
          webState: _runningNoTailnet,
          pairingCode: 'STAR-LYRA-1234',
        ),
        settingsDaoProvider.overrideWithValue(_FailingSettingsDao(database)),
      ],
    );

    final portField = find.byKey(const ValueKey('remote-access-port'));
    expect(tester.widget<TextField>(portField).controller!.text, '8080');

    await tester.enterText(portField, '9090');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump();

    expect(tester.widget<TextField>(portField).controller!.text, '8080');
    expect(
      find.text('Could not save the port. The previous value was restored.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'reachable_renders_tailnet_host_not_lan: shows the 100.x host + URL, '
      'never the LAN address', (tester) async {
    await pumpAppScreen(
      tester,
      const RemoteAccessSettings(),
      size: const Size(900, 1400),
      extraOverrides: _overrides(
        webState: _runningTailnet,
        pairingCode: 'STAR-LYRA-1234',
      ),
    );

    // The reachable pill shows the tailnet host.
    expect(find.textContaining('100.96.0.7'), findsWidgets,
        reason: 'Reachable panel must surface the tailnet host');
    // The bracket-correct (IPv4 here) URL is shown for copy/verify. It carries
    // WebServerState.dashboardPath, because bare `host:port` is not the
    // dashboard entry point — pasting it would land the operator on a 404.
    expect(find.text('http://100.96.0.7:8080${WebServerState.dashboardPath}'),
        findsOneWidget,
        reason: 'Reachable panel must show the tailnet dashboard URL');

    // A QR carrying the *tailnet* host is armed (pairing code is active). The
    // screen also shows the separate LAN pairing QR; we identify the Tailscale
    // one by its semantics label and assert it never embeds the LAN address.
    expect(_tailscaleQrFinder, findsOneWidget,
        reason: 'An active pairing code must arm the Tailscale QR');
    final qr = tester.widget<QrImageView>(_tailscaleQrFinder);
    expect(qr.semanticsLabel, contains('100.96.0.7:8080'));
    expect(qr.semanticsLabel, isNot(contains('192.168.1.50')),
        reason: 'Tailscale QR must never embed the LAN address');
  });

  testWidgets('not_detected_shows_alert_recheck_and_manual_field',
      (tester) async {
    await pumpAppScreen(
      tester,
      const RemoteAccessSettings(),
      size: const Size(900, 1400),
      extraOverrides: _overrides(
        webState: _runningNoTailnet,
        pairingCode: 'STAR-LYRA-1234',
      ),
    );

    expect(find.textContaining('No Tailscale address detected'), findsOneWidget,
        reason: 'No-tailnet branch must show the info alert title');
    expect(find.widgetWithText(SkotiqButton, 'Re-check'), findsOneWidget,
        reason: 'No-tailnet branch must offer a Re-check action');
    expect(find.text('Tailscale address (manual)'), findsOneWidget,
        reason: 'No-tailnet branch must offer a manual host field');
    // No tailnet host => the Tailscale QR must not render even though a
    // pairing code exists (the separate LAN QR may still appear).
    expect(_tailscaleQrFinder, findsNothing,
        reason:
            'Without a usable tailnet host the Tailscale QR must not render');
  });

  testWidgets('recheck_button_reresolves_without_dropping_state',
      (tester) async {
    _StubWebServerNotifier? captured;
    await pumpAppScreen(
      tester,
      const RemoteAccessSettings(),
      size: const Size(900, 1400),
      extraOverrides: _overrides(
        webState: _runningNoTailnet,
        pairingCode: 'STAR-LYRA-1234',
        captureWeb: (n) => captured = n,
      ),
    );

    expect(captured, isNotNull);
    expect(captured!.setRunningCalls, 0);

    // The LAN pairing card above now carries the phrase, its countdown and a
    // Stop button, so Re-check can sit below a fixed-size test viewport.
    final recheck = find.widgetWithText(SkotiqButton, 'Re-check');
    await tester.ensureVisible(recheck);
    await tester.pump();
    await tester.tap(recheck);
    await tester.pump();

    expect(captured!.setRunningCalls, 1,
        reason: 'Re-check must replay the running params to trigger a rescan');
    // The replayed params preserve the runtime fields.
    expect(captured!.state.isRunning, isTrue);
    expect(captured!.state.actualPort, 8080);
    expect(
        captured!.state.serverFingerprint, 'abcdef0123456789abcdef0123456789');
  });

  testWidgets('manual_lan_host_is_rejected', (tester) async {
    await pumpAppScreen(
      tester,
      const RemoteAccessSettings(),
      size: const Size(900, 1400),
      extraOverrides: _overrides(
        webState: _runningNoTailnet,
        pairingCode: 'STAR-LYRA-1234',
      ),
    );

    // A LAN address is not a tailnet host — must be refused.
    await tester.enterText(
      find.byType(SkotiqTextField).first,
      '192.168.1.50',
    );
    await tester.pump();

    expect(find.textContaining('Not a Tailscale address'), findsOneWidget,
        reason: 'A LAN host must be rejected with a clear validation error');
    expect(_tailscaleQrFinder, findsNothing,
        reason: 'A rejected manual host must not build the Tailscale QR');
  });

  testWidgets('manual_tailnet_host_builds_qr', (tester) async {
    await pumpAppScreen(
      tester,
      const RemoteAccessSettings(),
      size: const Size(900, 1400),
      extraOverrides: _overrides(
        webState: _runningNoTailnet,
        pairingCode: 'STAR-LYRA-1234',
      ),
    );

    await tester.enterText(
      find.byType(SkotiqTextField).first,
      '100.96.0.7',
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // No validation error, and the Tailscale QR appears for the manual host.
    expect(find.textContaining('Not a Tailscale address'), findsNothing);
    expect(_tailscaleQrFinder, findsOneWidget,
        reason: 'A valid manual tailnet host + pairing code must build a QR');

    // The QR's semantics label proves we embedded the *tailnet* host (and the
    // API port), not the LAN address — the panel sets it to
    // "Skotiq Tailscale pairing QR for <host>:<port>".
    final qr = tester.widget<QrImageView>(_tailscaleQrFinder);
    expect(qr.semanticsLabel, contains('100.96.0.7:8080'));
    expect(qr.semanticsLabel, isNot(contains('192.168.1.50')));
  });
}
