// Closing a linked desktop client must not safe (park) the host it views: a
// SIGTERM to a viewer parked the host's mount through the network, in the
// middle of the host's run.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/desktop_shutdown_safing.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _SpySafeRig extends SafeRigService {
  _SpySafeRig(super.ref) : super(stopSecondaryRig: () async => false);

  int calls = 0;

  @override
  Future<SafeRigResult> safeTheRig({
    required String reason,
    bool park = true,
    bool closeDome = false,
    bool closeCover = false,
    bool abortExposure = false,
    bool disableCooling = false,
    bool quiesceSecondaryRig = true,
    IdleMountPolicy idleMount = IdleMountPolicy.leave,
    bool notify = true,
  }) async {
    calls++;
    return const SafeRigResult();
  }
}

void main() {
  test('a linked client safes nothing on shutdown', () async {
    final backend = _MockNetworkBackend();
    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    late _SpySafeRig spy;
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        safeRigServiceProvider.overrideWith((ref) => spy = _SpySafeRig(ref)),
      ],
    );
    addTearDown(container.dispose);

    expect(await safeRigForDesktopShutdown(container), isFalse);
    container.read(safeRigServiceProvider);
    expect(spy.calls, 0);
  });
}
