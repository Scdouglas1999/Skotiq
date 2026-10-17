// A scan that found nothing has to say as much as one that found something.
//
// Live finding: the classes with no simulator collapsed to a bare italic
// "No switches found" line with a refresh icon. Nothing on screen said which
// backends had been asked, whether any of them had errored, or how to add a
// device that lives on another machine — even though the app log recorded
// "Discovery complete for Switch: 0 devices, 0 backend errors".
//
// 06 §Equipment replaced the per-class group boxes with ONE flat list and one
// empty state, so the same guarantee is now asserted against that empty state.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_app/screens/equipment/widgets/discovery_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

/// Pins the discovery state so the section chrome can be asserted without
/// running a real scan.
class _StubDiscoveryNotifier extends UnifiedDiscoveryNotifier {
  _StubDiscoveryNotifier(super.ref, UnifiedDiscoveryState seed) {
    state = seed;
  }
}

UnifiedDiscoveryState _scannedNothing() {
  return UnifiedDiscoveryState(
    backendStates: {
      DriverType.native: BackendDiscoveryState(
        backend: DriverType.native,
        status: DiscoveryStatus.completed,
        completedAt: DateTime(2026, 8, 4, 21),
      ),
      DriverType.indi: const BackendDiscoveryState(
        backend: DriverType.indi,
        status: DiscoveryStatus.error,
        error: 'INDI server connection failed',
      ),
    },
  );
}

Future<void> _pumpExpandedPanel(
  WidgetTester tester, {
  Size size = const Size(1280, 1600),
}) async {
  await pumpAppScreen(
    tester,
    const SingleChildScrollView(child: DiscoveryPanel()),
    size: size,
    settle: false,
    extraOverrides: [
      unifiedDiscoveryProvider.overrideWith(
        (ref) => _StubDiscoveryNotifier(ref, _scannedNothing()),
      ),
    ],
  );
  await tester.pump();
  await tester.tap(_iconButton('Expand'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// `SkotiqIconButton` carries its tooltip through `Semantics` and
/// `SkotiqTooltip`, not a Material `Tooltip`, so `find.byTooltip` misses it.
Finder _iconButton(String tooltip) => find.byWidgetPredicate(
      (w) => w is SkotiqIconButton && w.tooltip == tooltip,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a scan that found nothing keeps the drawer chrome and a count',
      (tester) async {
    await _pumpExpandedPanel(tester);

    expect(find.text('DISCOVERED DEVICES'), findsOneWidget);
    expect(find.textContaining('0 found'), findsOneWidget);
    expect(find.text('No devices found'), findsOneWidget);
  });

  testWidgets('the empty state names the backends it searched and which failed',
      (tester) async {
    await _pumpExpandedPanel(tester);

    // Enum-declaration order (ascom, alpaca, indi, native, simulator) so the
    // list is stable between scans rather than following map insertion.
    expect(
      find.textContaining('Searched: INDI (failed), Native'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Alpaca or INDI'),
      findsOneWidget,
      reason: 'a scan with nothing found must offer a route to adding one',
    );
  });

  // The head row is the widest this Row ever gets: the radio icon, the
  // eyebrow, the summary, two scans and the chevron. Measured at 312px it
  // overflowed by 243px, so below 520 the summary drops and the two scans
  // become icon buttons.
  testWidgets('the discovery head row fits a 360dp phone', (tester) async {
    await _pumpExpandedPanel(tester, size: const Size(360, 1600));

    expect(
      tester.takeException(),
      isNull,
      reason: 'the discovery head row must not overflow at phone width',
    );
    expect(find.text('DISCOVERED DEVICES'), findsOneWidget);
    expect(_iconButton('Scan all'), findsOneWidget);
    expect(_iconButton('Rescan'), findsOneWidget);
  });
}
