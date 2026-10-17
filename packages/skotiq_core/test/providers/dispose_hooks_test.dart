import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/sequence_provider.dart';

import '../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

// : verifies long-lived notifiers / providers tear down
// their owned timers and subscriptions when the ProviderContainer is
// disposed. Dart's test binding raises a "Timer is still pending"
// assertion if anything leaks past container teardown.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late MockBackend mockBackend;
  late StreamController<SkotiqEvent> eventStreamController;

  setUpAll(() {
    registerMocktailFallbackValues();
  });

  setUp(() {
    mockBackend = MockBackend();
    eventStreamController = StreamController<SkotiqEvent>.broadcast();

    when(
      () => mockBackend.eventStream,
    ).thenAnswer((_) => eventStreamController.stream);
    when(
      () => mockBackend.polarAlignmentEvents,
    ).thenAnswer((_) => const Stream.empty());

    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, mockBackend),
        ),
      ],
    );
  });

  tearDown(() async {
    await eventStreamController.close();
    container.dispose();
  });

  test(
    'sequenceExecutorProvider runs onDispose hook on container teardown without leaking timers',
    () {
      // Force the executor to instantiate. The dispose hook registered via
      // ref.onDispose must run when the container is disposed below — if any
      // owned timer survives teardown the test binding will raise a
      // "Timer is still pending" assertion.
      final executor = container.read(sequenceExecutorProvider);
      expect(executor, isNotNull);

      // Disposing the container fires ref.onDispose(executor.dispose).
      container.dispose();
    },
  );

  // Target search has no dispose-hook test: its canonical implementation is
  // the autoDispose screen-local provider in
  // `skotiq_app/lib/screens/framing/framing_search_provider.dart`, which
  // performs awaited async work instead of scheduling timers.
}
