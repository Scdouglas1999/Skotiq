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

PhotometricTransformRow _transform(String filterName) =>
    PhotometricTransformRow(
      id: filterName.hashCode,
      filterName: filterName,
      colorTerm: 0.1,
      extinctionCoefficient: 0.2,
      zeroPoint: 20,
      rmsResidual: 0.01,
      matchedStarCount: 12,
      catalogSource: 'test',
      dateComputed: DateTime.utc(2026, 7, 14),
    );

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for transform polling');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  test('transform polling retains data through a blip and resumes', () async {
    final backend = _MockNetworkBackend();
    final first = [_transform('R')];
    final updated = [_transform('V')];
    var calls = 0;
    when(() => backend.getPhotometricTransforms(profileId: null)).thenAnswer((
      _,
    ) async {
      calls++;
      if (calls == 3) throw StateError('temporary host failure');
      return calls >= 4 ? updated : first;
    });
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
        remotePhotometricTransformPollIntervalProvider.overrideWithValue(
          const Duration(milliseconds: 5),
        ),
      ],
    );
    addTearDown(container.dispose);

    final values = <List<PhotometricTransformRow>>[];
    final errors = <Object>[];
    final subscription = container.listen(allPhotometricTransformsProvider, (
      previous,
      next,
    ) {
      if (next.hasValue) values.add(next.requireValue);
      if (next.hasError) errors.add(next.error!);
    }, fireImmediately: true);
    addTearDown(subscription.close);

    await _waitUntil(() => calls >= 5 && values.length >= 2);

    expect(values.map((rows) => rows.single.filterName), ['R', 'V']);
    expect(errors, isEmpty);
  });
}
