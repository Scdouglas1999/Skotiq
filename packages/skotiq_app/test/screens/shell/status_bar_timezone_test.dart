// The clock the operator always has on screen must follow Settings → Location →
// Timezone.
//
// Formatting `DateTime.now()` (status bar) or `observationTimeProvider.time`
// (header) directly instead of asking `clockProvider` leaves both chips on the
// host's wall time with "Use system time" OFF and a site offset chosen — the
// setting persists, the row's subtitle updates, and nothing else in the app
// moves, so a remote-observatory operator reads their laptop's time while the UI
// claims the site's zone.
//
// The offsets here are derived from the HOST offset at run time, so the
// expected reading always differs from host-local by a known five hours no
// matter which machine runs the suite.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/status_bar.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/pump_app_screen.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this.initial);

  final AppSettingsState initial;

  @override
  Future<AppSettingsState> build() async => initial;
}

/// A `UTC±HH:MM` label five hours ahead of this host, so the expected clock
/// reading can never coincide with host-local time.
String _fiveHoursAheadOfHost() {
  final target = DateTime.now().timeZoneOffset + const Duration(hours: 5);
  final sign = target.isNegative ? '-' : '+';
  final abs = target.abs();
  final hh = abs.inHours.toString().padLeft(2, '0');
  final mm = (abs.inMinutes % 60).toString().padLeft(2, '0');
  return 'UTC$sign$hh:$mm';
}

/// Seconds-since-midnight of an `HH:MM:SS` chip.
int _parseClock(String text) {
  final parts = text.split(':').map(int.parse).toList();
  return parts[0] * 3600 + parts[1] * 60 + parts[2];
}

/// Signed difference between two clock readings, folded across midnight.
int _diffSeconds(int a, int b) {
  var diff = (a - b) % 86400;
  if (diff > 43200) diff -= 86400;
  if (diff < -43200) diff += 86400;
  return diff;
}

/// The `HH:MM:SS` text rendered inside [ancestor].
String _clockTextIn(WidgetTester tester, Finder ancestor) {
  final texts = tester
      .widgetList<Text>(
        find.descendant(of: ancestor, matching: find.byType(Text)),
      )
      .map((t) => t.data)
      .whereType<String>()
      .where((t) => RegExp(r'^\d{2}:\d{2}:\d{2}$').hasMatch(t))
      .toList();
  expect(texts, hasLength(1), reason: 'expected exactly one wall clock');
  return texts.single;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the status-bar clock follows the chosen site timezone',
      (tester) async {
    final timezone = _fiveHoursAheadOfHost();
    final hostBefore = DateTime.now();

    await pumpAppScreen(
      tester,
      const Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [StatusBar()],
      ),
      size: const Size(2600, 900),
      extraOverrides: [
        appSettingsProvider.overrideWith(
          () => _StubAppSettingsNotifier(
            AppSettingsState(timezone: timezone, useSystemTime: false),
          ),
        ),
      ],
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    final shown = _parseClock(_clockTextIn(tester, find.byType(StatusBar)));
    final hostSeconds =
        hostBefore.hour * 3600 + hostBefore.minute * 60 + hostBefore.second;

    expect(
      _diffSeconds(shown, hostSeconds),
      inInclusiveRange(5 * 3600 - 5, 5 * 3600 + 5),
      reason: 'the bar must read the site clock ($timezone), not the host',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('"Use system time" leaves the status-bar clock host-local',
      (tester) async {
    final hostBefore = DateTime.now();

    await pumpAppScreen(
      tester,
      const Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [StatusBar()],
      ),
      size: const Size(2600, 900),
      extraOverrides: [
        appSettingsProvider.overrideWith(
          () => _StubAppSettingsNotifier(
            AppSettingsState(
              timezone: _fiveHoursAheadOfHost(),
              useSystemTime: true,
            ),
          ),
        ),
      ],
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 50));

    final shown = _parseClock(_clockTextIn(tester, find.byType(StatusBar)));
    final hostSeconds =
        hostBefore.hour * 3600 + hostBefore.minute * 60 + hostBefore.second;

    expect(
      _diffSeconds(shown, hostSeconds),
      inInclusiveRange(-5, 5),
      reason: 'the site offset must be ignored while system time is on',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
