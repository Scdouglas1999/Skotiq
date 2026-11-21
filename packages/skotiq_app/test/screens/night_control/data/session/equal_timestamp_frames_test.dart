import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/night_control/data/session/session_frames_provider.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';

import '../../../../harness/mock_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  test('a reversed viewer list numbers the later id second', () async {
    const at = 1710000000000;
    final backend = _MockNetworkBackend();
    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    when(
      () => backend.getAllImageRows(),
    ).thenAnswer((_) async => [_row(2, at), _row(1, at)]);
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(sessionImageRowsProvider(7), (_, __) {});
    addTearDown(sub.close);
    for (
      var i = 0;
      i < 50 && !container.read(sessionImageRowsProvider(7)).hasValue;
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final lights = container.read(sessionImageRowsProvider(7)).requireValue;
    expect(nightFrameNumberForPath(lights, '/frame2.fits'), 2);
    expect(lights.map((row) => row.id), [1, 2]);
  });
}

Map<String, dynamic> _row(int id, int at) => {
  'id': id,
  'filePath': '/frame$id.fits',
  'fileName': 'frame$id.fits',
  'fileFormat': 'fits',
  'frameType': 'light',
  'exposureDuration': 60,
  'binX': 1,
  'binY': 1,
  'sessionId': 7,
  'capturedAt': at,
  'createdAt': at,
  'isAccepted': true,
  'isPlateSolved': false,
};
