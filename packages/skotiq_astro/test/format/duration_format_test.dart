import 'package:skotiq_astro/format.dart';
import 'package:test/test.dart';

void main() {
  String f(num s, DurationStyle style) =>
      DurationFormat.seconds(s, style: style);

  test('exact shows every unit from the largest down', () {
    expect(f(3723, DurationStyle.exact), '1h 2m 3s');
    expect(f(3600, DurationStyle.exact), '1h 0m 0s');
    expect(f(123, DurationStyle.exact), '2m 3s');
    expect(f(3, DurationStyle.exact), '3s');
    expect(DurationFormat.seconds(3723), '1h 2m 3s');
  });

  test('short shows two units and drops a zero second one', () {
    expect(f(3723, DurationStyle.short), '1h 2m');
    expect(f(7200, DurationStyle.short), '2h');
    expect(f(123, DurationStyle.short), '2m 3s');
    expect(f(120, DurationStyle.short), '2m');
    expect(f(3, DurationStyle.short), '3s');
  });

  test('coarse drops seconds once a minute has passed', () {
    expect(f(3723, DurationStyle.coarse), '1h 2m');
    expect(f(7200, DurationStyle.coarse), '2h');
    expect(f(123, DurationStyle.coarse), '2m');
    expect(f(59, DurationStyle.coarse), '59s');
  });

  test('roundToMinute carries a 60th minute into the hours', () {
    String r(num s) => DurationFormat.seconds(
      s,
      style: DurationStyle.coarse,
      roundToMinute: true,
    );
    expect(r(3599), '1h');
    expect(r(150), '3m');
    expect(r(45), '45s');
  });

  test('no style prints 0m for a run that captured something', () {
    for (final style in DurationStyle.values) {
      expect(f(12, style), '12s');
      expect(f(0.6, style), '1s');
    }
  });

  test('zero, negative and non-finite read 0s', () {
    for (final style in DurationStyle.values) {
      expect(f(0, style), '0s');
      expect(f(-5, style), '0s');
      expect(f(double.nan, style), '0s');
      expect(f(double.infinity, style), '0s');
    }
    expect(DurationFormat.of(Duration.zero), '0s');
  });

  test('rounding', () {
    expect(DurationFormat.seconds(59.6), '1m 0s');
    expect(
      DurationFormat.seconds(59.6, rounding: DurationRounding.truncate),
      '59s',
    );
    expect(DurationFormat.of(const Duration(milliseconds: 59600)), '59s');
  });

  test('decimal hours from one hour up', () {
    expect(DurationFormat.decimalHours(5400), '1.5h');
    expect(DurationFormat.decimalHours(44280), '12.3h');
    expect(DurationFormat.decimalHours(140 * 3600), '140h');
    expect(DurationFormat.decimalHours(2700), '45m');
    expect(DurationFormat.decimalHours(30), '30s');
    expect(DurationFormat.decimalHours(0), '0s');
  });
}
