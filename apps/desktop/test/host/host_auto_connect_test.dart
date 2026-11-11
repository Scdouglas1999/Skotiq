import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless/headless_auto_connect_bootstrap.dart';

/// Contract coverage for the headless startup auto-connect seam.
///
///   * On a ready local [FfiBackend] it drives [ProfileService]'s
///     `autoConnectOnStartup` exactly once and logs completion.
///   * A failure inside auto-connect must NOT propagate — the daemon has to
///     stay up so the operator can recover remotely (server survival).
///   * If the backend is not a ready local FfiBackend (readiness not yet
///     landed, or a misconfigured remote), it skips rather than driving
///     someone else's rig.
class _MockFfiBackend extends Mock implements FfiBackend {}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _RecordingProfileService extends ProfileService {
  _RecordingProfileService(super.ref, {this.error});

  final Object? error;
  int calls = 0;

  @override
  Future<void> autoConnectOnStartup() async {
    calls++;
    if (error != null) throw error!;
  }
}

class _RecordingLogger extends LoggingService {
  final List<String> infos = [];
  final List<String> warnings = [];
  final List<String> errors = [];

  @override
  void debug(String message, {String? source, Map<String, Object?>? fields}) {}
  @override
  void info(String message, {String? source, Map<String, Object?>? fields}) =>
      infos.add(message);
  @override
  void warning(
    String message, {
    String? source,
    Map<String, Object?>? fields,
  }) => warnings.add(message);
  @override
  void error(String message, {String? source, Map<String, Object?>? fields}) =>
      errors.add(message);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer containerFor(
    SkotiqBackend backend, {
    Object? autoConnectError,
  }) {
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        profileServiceProvider.overrideWith(
          (ref) => _RecordingProfileService(ref, error: autoConnectError),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  _RecordingProfileService serviceOf(ProviderContainer container) =>
      container.read(profileServiceProvider) as _RecordingProfileService;

  _MockFfiBackend readyFfi() {
    final backend = _MockFfiBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    return backend;
  }

  test(
    'runs auto-connect once and logs completion on a ready FfiBackend',
    () async {
      final container = containerFor(readyFfi());
      final logger = _RecordingLogger();

      await headlessAutoConnectBootstrap(container: container, logger: logger);

      expect(serviceOf(container).calls, 1);
      expect(logger.infos.any((m) => m.contains('completed')), isTrue);
      expect(logger.errors, isEmpty);
    },
  );

  test('swallows auto-connect failure so the daemon keeps running', () async {
    final container = containerFor(
      readyFfi(),
      autoConnectError: Exception('every device offline'),
    );
    final logger = _RecordingLogger();

    // Must complete normally — a throw here would crash the daemon boot.
    await expectLater(
      headlessAutoConnectBootstrap(container: container, logger: logger),
      completes,
    );

    expect(serviceOf(container).calls, 1);
    expect(logger.errors, isNotEmpty);
    expect(logger.errors.first, contains('recover'));
  });

  test(
    'skips (connects nothing) when the backend is not a ready FfiBackend',
    () async {
      final container = containerFor(DisconnectedBackend());
      final logger = _RecordingLogger();

      await headlessAutoConnectBootstrap(container: container, logger: logger);

      expect(serviceOf(container).calls, 0);
      expect(logger.warnings.any((m) => m.contains('skipped')), isTrue);
    },
  );

  test('skips a misconfigured remote NetworkBackend', () async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    final container = containerFor(backend);
    final logger = _RecordingLogger();

    await headlessAutoConnectBootstrap(container: container, logger: logger);

    expect(serviceOf(container).calls, 0);
    expect(logger.warnings.any((m) => m.contains('skipped')), isTrue);
  });

  // Backend-readiness orchestration seam. main_headless invokes this ONLY after
  // startHeadlessServices has started the API server, then hands in the
  // `useLocalBackend()` readiness future. A readiness FAILURE must be logged and
  // swallowed HERE so the already-running server survives — it must never
  // propagate to main_headless's outer catch (which would shut the server down).

  test(
    'readiness failure is logged and swallowed — server is not torn down and '
    'auto-connect is NOT attempted',
    () async {
      final container = containerFor(readyFfi());
      final logger = _RecordingLogger();

      // A throw here would reach main_headless's outer catch and exit — so the
      // seam MUST complete normally instead.
      await expectLater(
        headlessAutoConnectBootstrap(
          container: container,
          logger: logger,
          backendReady: Future<void>.error(Exception('backend never came up')),
        ),
        completes,
      );

      expect(serviceOf(container).calls, 0);
      expect(logger.errors, isNotEmpty);
      expect(logger.errors.first, contains('recover'));
    },
  );

  test(
    'successful readiness performs exactly one auto-connect attempt',
    () async {
      final container = containerFor(readyFfi());
      final logger = _RecordingLogger();

      await headlessAutoConnectBootstrap(
        container: container,
        logger: logger,
        backendReady: Future<void>.value(),
      );

      expect(serviceOf(container).calls, 1);
      expect(logger.infos.any((m) => m.contains('completed')), isTrue);
    },
  );

  test(
    'auto-connect is not attempted until backend readiness resolves (ordering)',
    () async {
      final container = containerFor(readyFfi());
      final logger = _RecordingLogger();
      final ready = Completer<void>();

      final future = headlessAutoConnectBootstrap(
        container: container,
        logger: logger,
        backendReady: ready.future,
      );

      // Let microtasks drain: the attempt must still be gated on readiness.
      await Future<void>.delayed(Duration.zero);
      expect(serviceOf(container).calls, 0);

      ready.complete();
      await future;
      expect(serviceOf(container).calls, 1);
    },
  );
}
