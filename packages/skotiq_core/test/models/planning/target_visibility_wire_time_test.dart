import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

Map<String, dynamic> _visibility(String rise) => {
  'currentAltitude': 40.0,
  'currentAzimuth': 120.0,
  'riseTime': rise,
  'moonDistance': 50.0,
};

void main() {
  const converter = TargetVisibilityInfoConverter();

  // A host and a client in different zones: the host's rise time arrives as
  // UTC with a Z and is the same instant on the client, in its local time.
  test('a rise time with an offset is the same instant, local here', () {
    final info = converter.fromJson(_visibility('2026-11-12T03:00:00.000Z'));
    expect(info.riseTime, DateTime.utc(2026, 11, 12, 3));
    expect(info.riseTime!.isUtc, isFalse);
  });

  // A host from before wire time sent its local wall clock with no offset.
  test('an old host\'s offset-less time reads as the same wall clock', () {
    final info = converter.fromJson(_visibility('2026-11-12T22:00:00.000'));
    expect(info.riseTime, DateTime(2026, 11, 12, 22));
  });

  test('the converter writes UTC with a Z', () {
    final info = converter.fromJson(_visibility('2026-11-12T03:00:00.000Z'));
    expect(converter.toJson(info)['riseTime'], '2026-11-12T03:00:00.000Z');
  });
}
