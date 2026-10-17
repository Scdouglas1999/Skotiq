import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

PhotometryMeasurementRow _measurement(String objectId) =>
    PhotometryMeasurementRow(
      id: objectId.hashCode,
      objectId: objectId,
      role: 'target',
      x: 10,
      y: 20,
      flux: 1234,
      isOutlier: false,
      timestamp: DateTime.utc(2026, 7, 14),
    );

RemoteScienceBundle _bundle([
  List<PhotometryMeasurementRow> photometry = const [],
]) => RemoteScienceBundle(
  photometry: photometry,
  calibrations: const [],
  transparency: const [],
  psfTiles: const [],
  frameQuality: const [],
  tileMetrics: const [],
  residuals: const [],
  movingObjects: const [],
  lineRatios: const [],
);

ProviderContainer _container(
  NetworkBackend backend, {
  required Duration interval,
}) => ProviderContainer(
  overrides: [
    backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
    remoteSciencePollIntervalProvider.overrideWithValue(interval),
  ],
);

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for remote science polling');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  test(
    'science bundle polling suppresses duplicates and recovers after a blip',
    () async {
      final backend = _MockNetworkBackend();
      final first = _bundle([_measurement('first')]);
      final updated = _bundle([_measurement('updated')]);
      var calls = 0;
      when(() => backend.getScienceSessionBundle(9)).thenAnswer((_) async {
        calls++;
        if (calls == 3) {
          throw StateError('temporary host failure');
        }
        return calls >= 4 ? updated : first;
      });
      final container = _container(
        backend,
        interval: const Duration(milliseconds: 5),
      );
      addTearDown(container.dispose);

      final values = <List<PhotometryMeasurementRow>>[];
      final errors = <Object>[];
      final subscription = container.listen(sessionPhotometryProvider(9), (
        previous,
        next,
      ) {
        if (next.hasValue) values.add(next.requireValue);
        if (next.hasError) errors.add(next.error!);
      }, fireImmediately: true);
      addTearDown(subscription.close);

      await _waitUntil(() => calls >= 5 && values.length >= 2);

      expect(values.map((rows) => rows.single.objectId), ['first', 'updated']);
      expect(errors, isEmpty);
    },
  );

  test('science bundle request is shared across derived providers', () async {
    final backend = _MockNetworkBackend();
    var calls = 0;
    when(() => backend.getScienceSessionBundle(4)).thenAnswer((_) async {
      calls++;
      return _bundle();
    });
    final container = _container(backend, interval: const Duration(minutes: 1));
    addTearDown(container.dispose);

    await Future.wait([
      container.read(sessionPhotometryProvider(4).future),
      container.read(sessionFrameCalibrationsProvider(4).future),
    ]);

    expect(calls, 1);
  });
}
