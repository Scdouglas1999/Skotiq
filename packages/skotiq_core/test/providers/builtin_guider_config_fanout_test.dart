import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../harness/in_memory_database.dart';

class _HostBackend extends Mock implements FfiBackend {}

class _ViewerBackend extends Mock implements NetworkBackend {}

class _Fixed extends BackendNotifier {
  _Fixed(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(const BuiltinGuiderConfig());
  });

  test('a built-in guider exposure change reaches the other window', () async {
    final saved = <BuiltinGuiderConfig>[];
    final hostBackend = _HostBackend();
    when(
      () => hostBackend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(
      () => hostBackend.builtinGuiderGetConfig(),
    ).thenAnswer((_) async => const BuiltinGuiderConfig(exposureSecs: 1));
    when(() => hostBackend.builtinGuiderSetConfig(any())).thenAnswer((
      invocation,
    ) async {
      saved.add(invocation.positionalArguments.single as BuiltinGuiderConfig);
    });
    final host = _container(hostBackend);
    await _loaded(host);

    final viewerA = await _viewer(const BuiltinGuiderConfig(exposureSecs: 1));
    final viewerB = await _viewer(const BuiltinGuiderConfig(exposureSecs: 1));
    clearInteractions(viewerA.backend);
    clearInteractions(viewerB.backend);

    await host
        .read(builtinGuiderConfigProvider.notifier)
        .updateConfig(const BuiltinGuiderConfig(exposureSecs: 2.5));
    expect(saved.single.exposureSecs, 2.5);
    expect(
      host.read(builtinGuiderConfigProvider).valueOrNull?.exposureSecs,
      2.5,
    );
    _apply(host, viewerA.container);
    _apply(host, viewerB.container);
    expect(
      viewerA.container
          .read(builtinGuiderConfigProvider)
          .valueOrNull
          ?.exposureSecs,
      2.5,
    );
    expect(
      viewerB.container
          .read(builtinGuiderConfigProvider)
          .valueOrNull
          ?.exposureSecs,
      2.5,
    );
    verifyNever(() => viewerA.backend.builtinGuiderGetConfig());
    verifyNever(() => viewerB.backend.builtinGuiderGetConfig());
    verifyNever(() => viewerA.backend.builtinGuiderSetConfig(any()));
    verifyNever(() => viewerB.backend.builtinGuiderSetConfig(any()));

    await host
        .read(builtinGuiderConfigProvider.notifier)
        .updateConfig(const BuiltinGuiderConfig(exposureSecs: 1.5));
    _apply(host, viewerA.container);
    _apply(host, viewerB.container);
    expect(saved.last.exposureSecs, 1.5);
    expect(
      viewerA.container
          .read(builtinGuiderConfigProvider)
          .valueOrNull
          ?.exposureSecs,
      1.5,
    );
    expect(
      viewerB.container
          .read(builtinGuiderConfigProvider)
          .valueOrNull
          ?.exposureSecs,
      1.5,
    );
    verifyNever(() => viewerA.backend.builtinGuiderGetConfig());
    verifyNever(() => viewerB.backend.builtinGuiderGetConfig());
  });
}

void _apply(ProviderContainer host, ProviderContainer viewer) {
  const BuiltinGuiderConfigChannel().apply(
    RuntimeApplyContext(viewer),
    const BuiltinGuiderConfigChannel().encode(
      host.read(builtinGuiderConfigProvider),
    ),
  );
}

Future<void> _loaded(ProviderContainer container) async {
  for (var i = 0; i < 20; i++) {
    if (container.read(builtinGuiderConfigProvider).hasValue) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('built-in guider config was not read');
}

Future<({ProviderContainer container, _ViewerBackend backend})> _viewer(
  BuiltinGuiderConfig initial,
) async {
  final backend = _ViewerBackend();
  when(
    () => backend.eventStream,
  ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
  when(() => backend.builtinGuiderGetConfig()).thenAnswer((_) async => initial);
  when(() => backend.builtinGuiderSetConfig(any())).thenAnswer((_) async {});
  final container = _container(backend);
  await _loaded(container);
  return (container: container, backend: backend);
}

ProviderContainer _container(SkotiqBackend backend) {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith((ref) => _Fixed(ref, backend)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}
