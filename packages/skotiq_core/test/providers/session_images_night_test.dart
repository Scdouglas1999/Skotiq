import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

CapturedImage _frame(String id, DateTime at) => CapturedImage(
  id: id,
  filePath: '/captures/$id.fits',
  capturedAt: at,
  settings: const ExposureSettings(exposureTime: 180, gain: 100, offset: 10),
);

/// Owner, 2026-11-08: "Linked session frames should always be from that
/// whole night. If for some reason the app crashes or is updated in the
/// middle of the night, we still want users to see that night's session."
void main() {
  final evening = DateTime(2026, 11, 7, 21);
  final afterMidnight = DateTime(2026, 11, 8, 2);
  final nextEvening = DateTime(2026, 11, 8, 20);

  test('a restart rebuilds the night, and frames that land meanwhile are '
      'not counted twice', () {
    final list = SessionImagesNotifier();
    // The restored run's first frame lands before the database read returns.
    list.addImage(_frame('3', afterMidnight));
    list.seedNight([
      _frame('1', evening),
      _frame('2', evening.add(const Duration(minutes: 3))),
      _frame('3', afterMidnight),
    ], now: afterMidnight);
    list.addImage(_frame('3', afterMidnight));

    expect(list.state.map((f) => f.id), ['1', '2', '3']);
  });

  test('noon to noon: a frame after midnight is the same night, the next '
      'evening starts a new one', () {
    final list = SessionImagesNotifier()
      ..addImage(_frame('1', evening))
      ..addImage(_frame('2', afterMidnight));
    expect(list.state, hasLength(2));

    list.addImage(_frame('3', nextEvening));
    expect(list.state.map((f) => f.id), ['3']);
  });

  test('the seed keeps only the night being imaged', () {
    final list = SessionImagesNotifier();
    list.seedNight([
      _frame('0', DateTime(2026, 11, 6, 23)),
      _frame('1', evening),
    ], now: afterMidnight);
    expect(list.state.map((f) => f.id), ['1']);
  });

  test('the night window runs from local noon to the next local noon', () {
    final window = observingNightWindow(afterMidnight);
    expect(window.start, DateTime(2026, 11, 7, 12));
    expect(window.end, DateTime(2026, 11, 8, 12));
    expect(observingNightWindow(evening), window);
  });
}
