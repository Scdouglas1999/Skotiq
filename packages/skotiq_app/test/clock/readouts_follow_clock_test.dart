// Every "now" a screen shows comes from clockProvider, so a replay, a remote
// site clock or a test can fix it in one place. These pin two readouts that
// used to read the wall clock directly: the title-bar clock and the session's
// running time.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/shell_clock.dart';
import 'package:skotiq_core/providers.dart';

import '../harness/pump_app_screen.dart';

/// A clock stopped at [at], in this machine's zone.
class _StoppedClock implements Clock {
  const _StoppedClock(this.at);
  final DateTime at;

  @override
  DateTime now() => at;
  @override
  DateTime nowUtc() => at.toUtc();
  @override
  Duration get utcOffset => at.timeZoneOffset;
  @override
  DateTime fromUtc(DateTime utc) => utc.toLocal();
}

class _Running extends SessionStateNotifier {
  _Running(super.ref, DateTime start) {
    // ignore: invalid_use_of_protected_member
    state = SessionState(isActive: true, startTime: start);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final stopped = DateTime(2026, 11, 15, 23, 47);

  testWidgets('the title-bar clock shows the clock provider\'s time',
      (tester) async {
    await pumpAppScreen(
      tester,
      const Material(child: Center(child: ShellClock())),
      settle: false,
      extraOverrides: [clockProvider.overrideWithValue(_StoppedClock(stopped))],
    );
    await tester.pump();
    expect(find.text('23:47'), findsOneWidget);
  });

  test('a running session counts its time from the clock provider', () {
    final container = ProviderContainer(
      overrides: [
        clockProvider.overrideWithValue(_StoppedClock(stopped)),
        sessionStateProvider.overrideWith(
          (ref) => _Running(ref, DateTime(2026, 11, 15, 18, 40)),
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(sessionDurationProvider), '05:07:00');
  });
}
