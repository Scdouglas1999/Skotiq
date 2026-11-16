// Start pairing on Settings > Remote access must produce all of it: the QR,
// the code as text, its expiry and a way out. A QR and nothing else leaves a
// blind operator no path to pair a phone at all.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/paired_devices.dart';
import 'package:skotiq_app/screens/settings/widgets/remote_access_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this._initial);

  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

/// Pairing parked mid-session with a live code and a known expiry.
class _StubPairingNotifier extends PairingNotifier {
  _StubPairingNotifier(String? pairingCode, Duration? remaining) {
    state = PairingState(
      pairingCode: pairingCode,
      expiresAt:
          remaining == null ? null : DateTime.now().add(remaining + oneSecond),
    );
  }

  /// The countdown floors to whole seconds, so a hair of slack keeps the
  /// rendered `mm:ss` off a boundary.
  static const oneSecond = Duration(milliseconds: 900);
}

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

const _running = WebServerState(
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
  required String? pairingCode,
  Duration? remaining,
  Size size = const Size(900, 1600),
}) async {
  final database = mockDatabase();
  addTearDown(database.close);
  await pumpAppScreen(
    tester,
    const RemoteAccessSettings(),
    size: size,
    database: database,
    extraOverrides: [
      appSettingsProvider.overrideWith(
        () => _StubAppSettingsNotifier(
          const AppSettingsState(webServerEnabled: true),
        ),
      ),
      pairingProvider
          .overrideWith((ref) => _StubPairingNotifier(pairingCode, remaining)),
      webServerStateProvider
          .overrideWith((ref) => _StubWebServerNotifier(_running)),
    ],
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pairing mode shows the phrase, its expiry and a way out',
      (tester) async {
    await _pumpRemoteAccess(
      tester,
      pairingCode: 'NOVA-NEBULA-2638',
      remaining: const Duration(minutes: 4, seconds: 1),
    );

    expect(
      find.text('NOVA-NEBULA-2638'),
      findsOneWidget,
      reason: 'the code is shown as text beside the QR',
    );
    expect(find.textContaining('Expires in 04:01'), findsOneWidget);
    expect(
      find.widgetWithText(SkotiqButton, 'Cancel pairing'),
      findsOneWidget,
      reason: 'navigating away was the only exit from pairing mode',
    );
  });

  testWidgets('the phrase is text, so assistive tech can read it',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpRemoteAccess(
      tester,
      pairingCode: 'NOVA-NEBULA-2638',
      remaining: const Duration(minutes: 4, seconds: 1),
    );

    final phrase = tester.getSemantics(find.text('NOVA-NEBULA-2638'));
    expect(
      '${phrase.label}${phrase.value}',
      contains('NOVA-NEBULA-2638'),
      reason: 'the QR image is the one part of this card AT cannot convey',
    );
    expect(find.bySemanticsLabel(RegExp('Expires in 04:01')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('before pairing starts the card still offers only Start',
      (tester) async {
    await _pumpRemoteAccess(tester, pairingCode: null);

    expect(
      find.widgetWithText(SkotiqButton, 'Cancel pairing'),
      findsNothing,
    );
  });

  // The phrase VALUE, not just its label, has to reach the accessibility tree.
  // A SelectableText publishes its text as a semantic value; without it the tree
  // reads "panel: Pairing phrase" then "panel: Expires in 4:49" with nothing
  // carrying the phrase between them, telling a screen-reader user that a phrase
  // exists and never what it is.
  testWidgets('the phrase has an accessible NAME, not only a value',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpRemoteAccess(
      tester,
      pairingCode: 'ZENITH-NOVA-5610',
      remaining: const Duration(minutes: 4, seconds: 49),
    );

    expect(
      find.bySemanticsLabel(RegExp('ZENITH-NOVA-5610')),
      findsOneWidget,
      reason: 'the QR is an image, so this text is the only non-visual path '
          'to pairing a phone',
    );
    handle.dispose();
  });

  // The group must not shrink-wrap while idle and snap to full width once
  // pairing starts: the page would reflow under the operator.
  group('the pairing group keeps one width', () {
    double groupWidth(WidgetTester tester, String eyebrow) => tester
        .getSize(find.ancestor(
          of: find.text(eyebrow),
          matching: find.byType(SettingsSection),
        ))
        .width;

    testWidgets('idle and pairing draw the same group', (tester) async {
      await _pumpRemoteAccess(
        tester,
        pairingCode: null,
        size: const Size(1600, 1200),
      );
      final idle = groupWidth(tester, 'PAIR A DEVICE');
      final webServer = groupWidth(tester, 'WEB SERVER');

      await _pumpRemoteAccess(
        tester,
        pairingCode: 'ZENITH-NOVA-5610',
        remaining: const Duration(minutes: 4, seconds: 49),
        size: const Size(1600, 1200),
      );
      final pairing = groupWidth(tester, 'PAIR A DEVICE');

      expect(idle, pairing,
          reason: 'the page reflowed under the operator when pairing started');
      expect(idle, webServer,
          reason: 'every group on the page runs the full content width');
    });
  });
}
