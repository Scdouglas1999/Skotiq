import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_app/widgets/startup_auto_connect_launcher.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Contract coverage for [StartupAutoConnectLauncher]'s role gating and
/// arm-until-classified behaviour:
///   * runs equipment auto-connect exactly once, and ONLY when the active
///     backend is a local hardware-owning [FfiBackend];
///   * skips a passive [NetworkBackend] (mobile / `--remote-host`) slave;
///   * stays ARMED through the desktop's first-frame
///     `DisconnectedBackend -> FfiBackend` swap — even a swap that lands AFTER
///     the diagnostic timeout still runs (no permanent skip);
///   * fires at most once across widget rebuilds and repeated transitions;
///   * disposal cancels the listener so a late swap never fires;
///   * an auto-connect failure surfaces exactly one user-visible notification
///     and never retries on rebuild.
class _MockFfiBackend extends Mock implements FfiBackend {}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend initial) {
    state = initial;
  }

  void swap(SkotiqBackend backend) => state = backend;
}

/// Records how many times auto-connect ran (and optionally throws to exercise
/// the user-visible failure path), without touching real hardware.
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

/// Records log calls so we can assert an error is logged exactly once.
class _RecordingLogger extends LoggingService {
  final List<String> infos = [];
  final List<String> errors = [];

  @override
  void debug(String message, {String? source, Map<String, Object?>? fields}) {}
  @override
  void info(String message, {String? source, Map<String, Object?>? fields}) =>
      infos.add(message);
  @override
  void warning(String message,
      {String? source, Map<String, Object?>? fields}) {}
  @override
  void error(String message, {String? source, Map<String, Object?>? fields}) =>
      errors.add(message);
}

void main() {
  ProviderContainer containerFor(
    SkotiqBackend initial, {
    Object? autoConnectError,
    LoggingService? logger,
  }) {
    return ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        loggingServiceProvider.overrideWithValue(logger ?? _RecordingLogger()),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, initial),
        ),
        profileServiceProvider.overrideWith(
          (ref) => _RecordingProfileService(ref, error: autoConnectError),
        ),
      ],
    );
  }

  Widget wrap(ProviderContainer container, {Widget child = const SizedBox()}) {
    return UncontrolledProviderScope(
      container: container,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: StartupAutoConnectLauncher(child: child),
      ),
    );
  }

  /// The same container/scope but WITHOUT the launcher — used to unmount it.
  Widget wrapWithoutLauncher(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(),
      ),
    );
  }

  int callCount(ProviderContainer container) =>
      (container.read(profileServiceProvider) as _RecordingProfileService)
          .calls;

  testWidgets('runs exactly once on a local FfiBackend master', (tester) async {
    final backend = _MockFfiBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    final container = containerFor(backend);
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    expect(callCount(container), 1);
  });

  testWidgets('skips a passive NetworkBackend (remote/mobile slave)', (
    tester,
  ) async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    final container = containerFor(backend);
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    expect(callCount(container), 0);
  });

  testWidgets('waits for the DisconnectedBackend -> FfiBackend swap, then runs',
      (
    tester,
  ) async {
    final ffi = _MockFfiBackend();
    when(
      () => ffi.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    final container = containerFor(DisconnectedBackend());
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pump(); // post-frame: _arm sees Disconnected, stays armed.
    expect(callCount(container), 0);

    // The desktop's local-backend swap lands a frame later.
    (container.read(backendProvider.notifier) as _TestBackendNotifier)
        .swap(ffi);
    await tester.pumpAndSettle();

    expect(callCount(container), 1);
  });

  testWidgets(
      'stays armed past the diagnostic timeout: a LATE FfiBackend swap still '
      'runs exactly once (no permanent skip)', (tester) async {
    final ffi = _MockFfiBackend();
    when(
      () => ffi.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    final container = containerFor(DisconnectedBackend());
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pump(); // _arm starts, stays armed.

    // Advance well past the 10s diagnostic timeout: it must NOT consume the one
    // shot and skip forever.
    await tester.pump(const Duration(seconds: 11));
    expect(callCount(container), 0);

    // The slow first backend swap finally lands at ~11s.
    (container.read(backendProvider.notifier) as _TestBackendNotifier)
        .swap(ffi);
    await tester.pumpAndSettle();

    expect(callCount(container), 1);
  });

  testWidgets('connects nothing while the backend stays DisconnectedBackend', (
    tester,
  ) async {
    final container = containerFor(DisconnectedBackend());
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();

    // Armed, but never a definitive FfiBackend -> nothing connected.
    expect(callCount(container), 0);
  });

  testWidgets('disposal cancels the listener — a swap after unmount never runs',
      (tester) async {
    final ffi = _MockFfiBackend();
    when(
      () => ffi.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    final container = containerFor(DisconnectedBackend());
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pump(); // armed, waiting on Disconnected.

    // Unmount the launcher (dispose -> listener closed).
    await tester.pumpWidget(wrapWithoutLauncher(container));
    await tester.pump();

    // A late swap after disposal must NOT drive auto-connect.
    (container.read(backendProvider.notifier) as _TestBackendNotifier)
        .swap(ffi);
    await tester.pumpAndSettle();

    expect(callCount(container), 0);
  });

  testWidgets('does not re-run auto-connect on widget rebuild', (tester) async {
    final backend = _MockFfiBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    final container = containerFor(backend);
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container, child: const SizedBox()));
    await tester.pumpAndSettle();
    expect(callCount(container), 1);

    // Rebuild the launcher (same State is preserved) with a different child.
    await tester.pumpWidget(
      wrap(container, child: const SizedBox(width: 1, height: 1)),
    );
    await tester.pumpAndSettle();

    expect(callCount(container), 1);
  });

  testWidgets('repeated backend transitions never duplicate the run', (
    tester,
  ) async {
    final ffi = _MockFfiBackend();
    when(
      () => ffi.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    final container = containerFor(DisconnectedBackend());
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pump();

    final notifier =
        container.read(backendProvider.notifier) as _TestBackendNotifier;
    notifier.swap(ffi);
    await tester.pumpAndSettle();
    expect(callCount(container), 1);

    // Flap the backend and rebuild — the one shot is already consumed.
    notifier.swap(DisconnectedBackend());
    await tester.pump();
    notifier.swap(ffi);
    await tester.pumpWidget(
      wrap(container, child: const SizedBox(width: 2, height: 2)),
    );
    await tester.pumpAndSettle();

    expect(callCount(container), 1);
  });

  testWidgets(
      'auto-connect failure surfaces exactly one notification and does not '
      'retry on rebuild', (tester) async {
    final ffi = _MockFfiBackend();
    when(
      () => ffi.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    final logger = _RecordingLogger();
    final container = containerFor(
      ffi,
      autoConnectError: const ProfileAutoConnectException(
        profileName: 'Rig',
        failures: ['camera: offline'],
      ),
      logger: logger,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pumpAndSettle();

    // Ran once, and surfaced exactly one user-visible error notification.
    expect(callCount(container), 1);
    final notifications = container.read(uiNotificationProvider);
    expect(notifications, hasLength(1));
    expect(notifications.single.level, UiNotificationLevel.error);
    expect(notifications.single.title, 'Equipment auto-connect');
    expect(notifications.single.message, contains('camera: offline'));
    // Logged exactly once — no duplicate diagnostics.
    expect(logger.errors, hasLength(1));

    // Rebuild: no retry, no second toast, no second log.
    await tester.pumpWidget(
      wrap(container, child: const SizedBox(width: 3, height: 3)),
    );
    await tester.pumpAndSettle();

    expect(callCount(container), 1);
    expect(container.read(uiNotificationProvider), hasLength(1));
    expect(logger.errors, hasLength(1));
  });
}
