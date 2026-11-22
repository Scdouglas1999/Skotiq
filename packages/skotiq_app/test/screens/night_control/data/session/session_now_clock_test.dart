// The session providers' "now" is the app clock's, from the first read on:
// a simulated or pinned clock moves Tonight's elapsed times too.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_format.dart';
import 'package:skotiq_core/providers.dart';

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

void main() {
  test('the session now reads the app clock before the first tick', () {
    final at = DateTime.utc(2031, 3, 4, 5, 6);
    final container = ProviderContainer(
      overrides: [clockProvider.overrideWithValue(_StoppedClock(at))],
    );
    addTearDown(container.dispose);

    expect(container.read(nightSessionNowProvider).isAtSameMomentAs(at), isTrue);
  });
}
