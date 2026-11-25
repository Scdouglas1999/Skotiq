// The phone shell: no shell bar, the bottom bar upright and a rail on its
// side, the keyboard takes the navigation away, and the status-bar inset is
// applied once by the shell rather than again by each screen.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';
import 'package:skotiq_app/screens/shell/shell_chrome.dart';
import 'package:skotiq_app/screens/shell/widgets/side_navigation.dart';
import 'package:skotiq_app/screens/shell/widgets/skotiq_bottom_navigation.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

class _PinnedSafetyNotifier extends WeatherSafetyNotifier {
  _PinnedSafetyNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    super.state = const WeatherSafetyState(
      status: WeatherSafetyStatus.safe,
      actions: WeatherSafetyActions(),
      currentAlertLevel: AlertLevel.clear,
      dataSource: SafetyDataSource.unavailable,
      monitoringEnabled: false,
    );
    _pinned = true;
  }

  bool _pinned = false;

  @override
  set state(WeatherSafetyState value) {
    if (_pinned) return;
    super.state = value;
  }
}

final _quiet = <Override>[
  activeTransientAlertsProvider.overrideWith(
    (ref) => Stream.value(const <TransientAlert>[]),
  ),
  railWeatherUnsafeProvider.overrideWithValue(false),
  railAnyDeviceConnectedProvider.overrideWithValue(true),
  weatherSafetyProvider.overrideWith(_PinnedSafetyNotifier.new),
];

/// What the routed screen sees of the shell.
class _Probe extends StatelessWidget {
  const _Probe();

  static EdgeInsets? padding;
  static bool? hasTrailing;

  @override
  Widget build(BuildContext context) {
    padding = MediaQuery.paddingOf(context);
    hasTrailing = ShellHeaderTrailing.maybeOf(context) != null;
    return const Text('Routed content');
  }
}

Future<HarnessHandle> _pumpPhoneShell(
  WidgetTester tester,
  Size size, {
  double keyboard = 0,
}) async {
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
  addTearDown(tester.view.resetPadding);
  final handle = await pumpAppScreen(
    tester,
    // The harness hosts screens in a Scaffold, which takes the keyboard out
    // of its body's MediaQuery; the app's shell is not inside one.
    Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(viewInsets: EdgeInsets.only(bottom: keyboard)),
        child: const AppShell(child: _Probe()),
      ),
    ),
    settle: false,
    extraOverrides: _quiet,
    size: size,
    registerTearDown: false,
  );
  addTearDown(handle.database.close);
  await tester.pump(const Duration(milliseconds: 200));
  return handle;
}

/// The shell's providers run periodic timers, and the binding checks for
/// pending timers before any tear-down runs, so each test ends with this.
Future<void> _dispose(WidgetTester tester, HarnessHandle handle) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 10));
  handle.container.dispose();
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  setUp(() => ShellChrome.debugNativeMobileOverride = true);
  tearDown(() => ShellChrome.debugNativeMobileOverride = null);

  testWidgets('upright: a bottom bar, no shell bar, insets applied once', (
    tester,
  ) async {
    final handle = await _pumpPhoneShell(tester, const Size(411, 860));

    final nav = tester.widget<SkotiqBottomNavigation>(
      find.byType(SkotiqBottomNavigation),
    );
    expect(nav.vertical, isFalse);
    // The screen's own header is the top bar and carries the shell's items.
    expect(_Probe.hasTrailing, isTrue);
    // The shell took the status bar; the bottom bar took the nav inset.
    expect(_Probe.padding!.top, 0);
    expect(_Probe.padding!.bottom, 0);
    // The bar sits below the routed content, not under the status bar.
    expect(
      tester.getTopLeft(find.text('Routed content')).dy,
      greaterThanOrEqualTo(24),
    );
    await _dispose(tester, handle);
  });

  testWidgets('on its side: the bar becomes a rail on the left', (
    tester,
  ) async {
    final handle = await _pumpPhoneShell(tester, const Size(860, 411));

    final finder = find.byType(SkotiqBottomNavigation);
    expect(tester.widget<SkotiqBottomNavigation>(finder).vertical, isTrue);
    final rail = tester.getRect(finder);
    expect(rail.left, 0);
    expect(rail.width, SkotiqBottomNavigation.railWidth);
    expect(
      tester.getTopLeft(find.text('Routed content')).dx,
      greaterThanOrEqualTo(rail.right),
    );
    await _dispose(tester, handle);
  });

  testWidgets(
      'the keyboard takes the bar away and the status bar stays covered', (
    tester,
  ) async {
    final handle =
        await _pumpPhoneShell(tester, const Size(411, 860), keyboard: 300);
    expect(find.byType(SkotiqBottomNavigation), findsNothing);
    // The status-bar inset stays with the shell while the keyboard is up.
    expect(_Probe.padding!.top, 0);
    expect(
      tester.getTopLeft(find.text('Routed content')).dy,
      greaterThanOrEqualTo(24),
    );
    await _dispose(tester, handle);
  });

  testWidgets('the keyboard hides the rail too', (tester) async {
    final handle =
        await _pumpPhoneShell(tester, const Size(860, 411), keyboard: 200);
    expect(find.byType(SkotiqBottomNavigation), findsNothing);
    await _dispose(tester, handle);
  });
}
