// "Start pairing mode to show a QR code and pairing phrase on this screen" must
// produce all of it. A QR and nothing else — no phrase, no expiry, no way to
// leave pairing mode, and a card that reduces in the accessibility tree to
// "panel: Pair phones and tablets" plus a disabled empty text node — leaves a
// blind operator no path to pair a phone at all.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/pairing_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/remote_access_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
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
      reason: 'the card promises a pairing phrase alongside the QR',
    );
    expect(find.textContaining('Expires in 4:01'), findsOneWidget);
    expect(
      find.widgetWithText(SkotiqButton, 'Stop pairing mode'),
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
    expect(find.bySemanticsLabel(RegExp('Expires in 4:01')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('before pairing starts the card still offers only Start',
      (tester) async {
    await _pumpRemoteAccess(tester, pairingCode: null);

    expect(
      find.widgetWithText(SkotiqButton, 'Stop pairing mode'),
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

  // The card must not shrink-wrap to ~530 px of a ~1150 px column while idle
  // and snap to full width once pairing starts.
  group('the card keeps one width', () {
    Future<double> cardWidth(WidgetTester tester) async {
      final card = find.ancestor(
        of: find.text('Pair phones and tablets'),
        matching: find.byType(Container),
      );
      return tester.getSize(card.first).width;
    }

    testWidgets('idle and pairing draw the same card', (tester) async {
      await _pumpRemoteAccess(
        tester,
        pairingCode: null,
        size: const Size(1600, 1200),
      );
      final idle = await cardWidth(tester);
      // The full-width neighbour on the same leaf.
      final browsersCard = tester
          .getSize(
            find
                .ancestor(
                  of: find.text('Pair remote browsers'),
                  matching: find.byType(Container),
                )
                .first,
          )
          .width;

      await _pumpRemoteAccess(
        tester,
        pairingCode: 'ZENITH-NOVA-5610',
        remaining: const Duration(minutes: 4, seconds: 49),
        size: const Size(1600, 1200),
      );
      final pairing = await cardWidth(tester);

      expect(
        idle,
        pairing,
        reason: 'the leaf reflowed under the operator when pairing started',
      );
      expect(
        idle,
        greaterThan(browsersCard * 0.8),
        reason: 'every other card on this leaf runs the full content width',
      );
    });
  });
}
