// The narrator runs on the imaging host. A companion reads the host's feed and
// never runs its own copy against its empty database.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/database/daos/narrator_events_dao.dart';
import 'package:skotiq_core/src/services/science/narrator/narrator_service.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockNarratorEventsDao extends Mock implements NarratorEventsDao {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void main() {
  test('a companion does not start a local narrator', () async {
    final backend = _MockNetworkBackend();
    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    final dao = _MockNarratorEventsDao();
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        narratorEventsDaoProvider.overrideWithValue(dao),
      ],
    );
    addTearDown(container.dispose);

    await NarratorService(container.read(_refProvider), sessionId: 7).start();

    verifyNever(() => dao.dedupeKeysForSession(any()));
  });
}

final _refProvider = Provider<Ref>((ref) => ref);
