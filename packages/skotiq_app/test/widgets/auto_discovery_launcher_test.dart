import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/widgets/auto_discovery_launcher.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockFfiBackend extends Mock implements FfiBackend {}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void swap(SkotiqBackend backend) => state = backend;
}

class _SettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        autoDiscoverOnLaunch: true,
        indiAutoConnect: false,
        alpacaAutoDiscover: false,
      );
}

class _RecordingDiscoveryNotifier extends UnifiedDiscoveryNotifier {
  _RecordingDiscoveryNotifier(super.ref);

  int calls = 0;

  @override
  Future<void> discoverAll({
    bool includeIndi = true,
    bool includeAlpaca = true,
  }) async {
    calls++;
  }
}

class _NoopLogger extends LoggingService {
  @override
  void debug(String message, {String? source, Map<String, Object?>? fields}) {}

  @override
  void info(String message, {String? source, Map<String, Object?>? fields}) {}

  @override
  void warning(
    String message, {
    String? source,
    Map<String, Object?>? fields,
  }) {}

  @override
  void error(String message, {String? source, Map<String, Object?>? fields}) {}
}

void main() {
  ProviderContainer createContainer(
    SkotiqBackend backend, {
    void Function(_SwappableBackendNotifier notifier)? captureBackend,
  }) {
    return ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) {
          final notifier = _SwappableBackendNotifier(ref, backend);
          captureBackend?.call(notifier);
          return notifier;
        }),
        appSettingsProvider.overrideWith(_SettingsNotifier.new),
        unifiedDiscoveryProvider.overrideWith(_RecordingDiscoveryNotifier.new),
        loggingServiceProvider.overrideWithValue(_NoopLogger()),
      ],
    );
  }

  Widget wrap(ProviderContainer container) => UncontrolledProviderScope(
        container: container,
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: AutoDiscoveryLauncher(child: SizedBox()),
        ),
      );

  int calls(ProviderContainer container) =>
      (container.read(unifiedDiscoveryProvider.notifier)
              as _RecordingDiscoveryNotifier)
          .calls;

  testWidgets('waits through a slow disconnected-to-local startup',
      (tester) async {
    late _SwappableBackendNotifier backendNotifier;
    final container = createContainer(
      DisconnectedBackend(),
      captureBackend: (notifier) => backendNotifier = notifier,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pump(const Duration(seconds: 2));
    expect(calls(container), 0);

    backendNotifier.swap(_MockFfiBackend());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 801));
    expect(calls(container), 1);
  });

  testWidgets('a disconnected-to-remote startup never discovers locally',
      (tester) async {
    late _SwappableBackendNotifier backendNotifier;
    final container = createContainer(
      DisconnectedBackend(),
      captureBackend: (notifier) => backendNotifier = notifier,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pump();
    backendNotifier.swap(_MockNetworkBackend());
    await tester.pump(const Duration(seconds: 2));

    expect(calls(container), 0);
  });

  testWidgets('does not launch after the local backend authority changes',
      (tester) async {
    late _SwappableBackendNotifier backendNotifier;
    final container = createContainer(
      _MockFfiBackend(),
      captureBackend: (notifier) => backendNotifier = notifier,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(wrap(container));
    await tester.pump();
    backendNotifier.swap(_MockNetworkBackend());
    await tester.pump(const Duration(milliseconds: 801));

    expect(calls(container), 0);
  });
}
