import 'package:logging/logging.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:test/test.dart';

/// A TLE file states what it got wrong once, not once per element set: the
/// active-satellites source alone has about 8000 sets.
void main() {
  const name = 'ISS (ZARYA)';
  const line1 =
      '1 25544U 98067A   08264.51782528 -.00002182  00000-0 -11606-4 0  2927';
  const line2 =
      '2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537';
  // Same set with a wrong checksum digit on line 1.
  const badSumLine1 =
      '1 25544U 98067A   08264.51782528 -.00002182  00000-0 -11606-4 0  2928';
  // Epoch day is not a number (which also breaks the checksum).
  const brokenLine1 =
      '1 25544U 98067A   08264.5178X528 -.00002182  00000-0 -11606-4 0  2927';

  late List<LogRecord> records;

  setUp(() {
    records = [];
    Logger.root.level = Level.ALL;
    final sub = Logger.root.onRecord
        .where((r) => r.loggerName == 'skotiq.SatelliteCatalog')
        .listen(records.add);
    addTearDown(sub.cancel);
  });

  test('many bad sets give one line per kind of problem', () {
    final text = [
      for (var i = 0; i < 50; i++) ...['SAT $i', badSumLine1, line2],
      for (var i = 0; i < 20; i++) ...['BROKEN $i', brokenLine1, line2],
      name,
      line1,
      line2,
    ].join('\n');

    final elements = TleParser.parse(text);

    expect(elements, hasLength(51));
    expect(records, hasLength(2));
    expect(records.every((r) => r.level == Level.WARNING), isTrue);
    expect(records[0].message, contains('Checksum mismatch in 70'));
    expect(records[0].message, contains('SAT 0'));
    expect(records[0].message, contains('and 67 more'));
    expect(records[1].message, contains('20 element set(s) could not'));
  });

  test('a clean file logs nothing', () {
    expect(TleParser.parse([name, line1, line2].join('\n')), hasLength(1));
    expect(records, isEmpty);
  });
}
