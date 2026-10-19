// Tonight's sun and moon land on the operator's clock exactly once.
//
// The provider used to stamp a "now" from `clock.now()` before the first
// tick and then move it onto the operator's clock a second time, so under a
// zone other than the host's the first frame put now hours away from the
// truth. "Now" is no longer part of these facts; the four instants and the
// moon are each converted once, from the true instant.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/tonight_night.dart';
import 'package:skotiq_app/services/observing_site.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// A zone five hours ahead of this host, so the expected fields can never
/// coincide with host-local ones.
FixedOffsetClock _fiveHoursAheadOfHost() => FixedOffsetClock(
      utcOffset: DateTime.now().timeZoneOffset + const Duration(hours: 5),
      label: 'test',
    );

/// The fields [utc] reads as in a zone [offset] ahead of UTC.
List<int> _fields(DateTime utc, Duration offset) {
  final shifted = utc.add(offset);
  return <int>[
    shifted.year,
    shifted.month,
    shifted.day,
    shifted.hour,
    shifted.minute,
  ];
}

List<int> _fieldsOf(DateTime t) =>
    <int>[t.year, t.month, t.day, t.hour, t.minute];

void main() {
  final sunset = DateTime.utc(2026, 10, 19, 22, 18);
  final dark = DateTime.utc(2026, 10, 19, 23, 48);
  final dawn = DateTime.utc(2026, 10, 20, 9, 44);
  final sunrise = DateTime.utc(2026, 10, 20, 11, 10);
  final moonSet = DateTime.utc(2026, 10, 20, 3, 9);

  ProviderContainer container(Clock clock) {
    final c = ProviderContainer(
      overrides: <Override>[
        clockProvider.overrideWithValue(clock),
        siteTwilightTimesProvider.overrideWithValue(
          TwilightTimes(
            sunset: sunset,
            astronomicalDusk: dark,
            astronomicalDawn: dawn,
            sunrise: sunrise,
          ),
        ),
        siteMoonTimesProvider.overrideWithValue(
          MoonTimes(moonset: moonSet, illumination: 44, phaseName: 'test'),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a chosen zone shifts every instant once, from the true instant', () {
    final clock = _fiveHoursAheadOfHost();
    final night = container(clock).read(tonightNightProvider)!;
    final offset = clock.utcOffset;

    expect(_fieldsOf(night.sunset), _fields(sunset, offset));
    expect(_fieldsOf(night.astroDark), _fields(dark, offset));
    expect(_fieldsOf(night.astroDawn), _fields(dawn, offset));
    expect(_fieldsOf(night.sunrise), _fields(sunrise, offset));
    expect(_fieldsOf(night.moonSet!), _fields(moonSet, offset));
    expect(night.moonIlluminationPercent, 44,
        reason: 'the planetarium already reports a percentage');
  });

  test('the system clock reads host local time', () {
    final night = container(const SystemClock()).read(tonightNightProvider)!;
    expect(night.sunset, sunset.toLocal());
    expect(night.sunrise, sunrise.toLocal());
  });

  test('no site, no night', () {
    final c = ProviderContainer(
      overrides: <Override>[
        siteTwilightTimesProvider.overrideWithValue(null),
        siteMoonTimesProvider.overrideWithValue(null),
      ],
    );
    addTearDown(c.dispose);
    expect(c.read(tonightNightProvider), isNull);
  });
}
