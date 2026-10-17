// Smoke tests for the widget-test harness itself.
//
// These verify the harness wires its three providers correctly and that
// extra overrides propagate. Higher-level screen tests will exercise the
// harness in anger; here we just guarantee the contract.

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'harness.dart';

/// A trivial probe widget that reads each harness-provided provider and
/// renders the resolved values so the test body can assert on them via
/// `find.text`. Why not just `container.read` inside the test: that would
/// short-circuit the widget tree and miss bugs where a provider is wired
/// at the container level but not visible to descendant widgets.
class _ProbeWidget extends ConsumerWidget {
  const _ProbeWidget();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backend = ref.watch(backendProvider);
    final database = ref.watch(databaseProvider);
    final version = ref.watch(appVersionProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('backend:${backend.runtimeType}', key: const ValueKey('backend')),
        Text('database:${database.runtimeType}',
            key: const ValueKey('database')),
        Text('version:$version', key: const ValueKey('version')),
      ],
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pumps a Container() and renders it', (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const Center(child: Text('hello harness')),
    );

    expect(find.text('hello harness'), findsOneWidget);
    expect(handle.backend, isA<MockBackend>());
    expect(handle.database, isA<SkotiqDatabase>());
  });

  testWidgets('default overrides reach descendants of ProviderScope',
      (tester) async {
    final handle = await pumpAppScreen(tester, const _ProbeWidget());

    // The backend provider should resolve to the MockBackend instance the
    // harness installed — proves TestBackendNotifier propagates.
    final backendText = tester.widget<Text>(findByDataKey('backend'));
    expect(backendText.data, contains('MockBackend'));

    // The database provider should resolve to the in-memory SkotiqDatabase
    // the harness installed.
    final databaseText = tester.widget<Text>(findByDataKey('database'));
    expect(databaseText.data, contains('SkotiqDatabase'));

    // The version override should match the default the harness installs
    // (callers can override but we didn't).
    final versionText = tester.widget<Text>(findByDataKey('version'));
    expect(versionText.data, equals('version:0.0.0-test+0'));

    // The handle's container should read the same MockBackend identity that
    // the widget tree sees.
    expect(handle.container.read(backendProvider), same(handle.backend));
  });

  testWidgets('extraOverrides win over harness defaults', (tester) async {
    const customVersion = AppVersionInfo(version: '9.9.9', buildNumber: 42);
    final handle = await pumpAppScreen(
      tester,
      const _ProbeWidget(),
      extraOverrides: [
        appVersionProvider.overrideWithValue(customVersion),
      ],
    );

    final versionText = tester.widget<Text>(findByDataKey('version'));
    expect(versionText.data, equals('version:9.9.9+42'));
    expect(handle.container.read(appVersionProvider), equals(customVersion));
  });

  testWidgets('callers can inject their own MockBackend and stub it',
      (tester) async {
    final customBackend = mockBackend();
    when(() => customBackend.getConnectedDevices()).thenAnswer((_) async => [
          const DeviceInfo(
            id: 'cam-1',
            name: 'Test Camera',
            deviceType: DeviceType.camera,
            driverType: DriverType.simulator,
            description: 'Simulated camera for harness smoke test',
            driverVersion: '1.0',
          ),
        ]);

    final handle = await pumpAppScreen(
      tester,
      const Center(child: Text('with backend')),
      backend: customBackend,
    );

    expect(handle.backend, same(customBackend));
    final devices = await handle.backend.getConnectedDevices();
    expect(devices, hasLength(1));
    expect(devices.first.id, equals('cam-1'));
  });

  testWidgets('mockDatabase produces a usable in-memory SkotiqDatabase',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      const Center(child: Text('db check')),
    );

    // Inserting a row and reading it back proves the schema is
    // materialised. We use the drift-generated companion directly so the
    // smoke test stays inside skotiq_app and doesn't depend on the
    // helpers that live in skotiq_core/test.
    final dao = handle.container.read(equipmentProfilesDaoProvider);
    final id = await dao.createProfile(
      EquipmentProfilesCompanion.insert(
        name: 'Harness Probe Profile',
        description: const Value('inserted by harness_test.dart'),
      ),
    );
    expect(id, greaterThan(0));

    final all = await dao.getAllProfiles();
    expect(all, hasLength(1));
    expect(all.first.name, equals('Harness Probe Profile'));
  });

  testWidgets('size override applied to tester.view', (tester) async {
    await pumpAppScreen(
      tester,
      const Center(child: Text('sized')),
      size: const Size(640, 480),
    );

    // Why query MediaQuery rather than tester.view: layout-sensitive
    // widgets consume MediaQuery, so the more meaningful assertion is that
    // the widget tree sees the expected logical size.
    final mediaQueryContext = tester.element(find.text('sized'));
    final media = MediaQuery.of(mediaQueryContext);
    expect(media.size.width, equals(640.0));
    expect(media.size.height, equals(480.0));
  });

  test('MockBackend.emitEvent forwards onto the mocked eventStream', () async {
    // Pure Dart test (no widget tree) — exercises just the event plumbing
    // so this isolates the wiring contract from any imaging-screen rebuild
    // side effects.
    final backend = mockBackend();
    final received = <SkotiqEvent>[];
    final sub = backend.eventStream.listen(received.add);

    backend.emitEvent(const SkotiqEvent(
      timestamp: 42,
      severity: EventSeverity.error,
      category: EventCategory.equipment,
      eventType: 'camera_fault',
      data: {'message': 'shutter stuck'},
    ));
    // Wait one microtask so the broadcast controller delivers the event.
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(received.first.eventType, equals('camera_fault'));
    expect(received.first.severity, equals(EventSeverity.error));

    await sub.cancel();
    backend.dispose();
  });

  test('MockBackend.emitPolarAlignmentEvent forwards onto polarAlignmentEvents',
      () async {
    final backend = mockBackend();
    final received = <Map<String, dynamic>>[];
    final sub = backend.polarAlignmentEvents.listen(received.add);

    backend.emitPolarAlignmentEvent(const {'kind': 'rotation', 'angle': 1.5});
    await Future<void>.delayed(Duration.zero);

    expect(received, hasLength(1));
    expect(received.first['kind'], equals('rotation'));
    expect(received.first['angle'], equals(1.5));

    await sub.cancel();
    backend.dispose();
  });

  test('MockBackend.emitEvent without factory wiring throws StateError', () {
    // Constructing MockBackend directly skips mockBackend()'s controller
    // wiring; emitEvent must fail loudly rather than silently no-op'ing,
    // because a silent drop would make it hard to debug why a widget test
    // never sees the event.
    final raw = MockBackend();
    expect(
      () => raw.emitEvent(const SkotiqEvent(
        timestamp: 0,
        severity: EventSeverity.info,
        category: EventCategory.system,
        eventType: 'noop',
        data: {},
      )),
      throwsStateError,
    );
  });
}
