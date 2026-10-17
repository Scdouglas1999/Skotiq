import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

class _MockBackend extends Mock implements SkotiqBackend {}

class _SwitchingBackendNotifier extends BackendNotifier {
  _SwitchingBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void replaceWith(SkotiqBackend backend) => state = backend;
}

class _ControlledDefectMapService extends DefectMapService {
  _ControlledDefectMapService(super.ref);

  final buildGates = <Completer<DefectMapStatus>>[];
  final calls = <String>[];
  DefectMapStatus? currentStatus;

  @override
  Future<DefectMapStatus> build({
    required String cameraId,
    required List<String> darkFramePaths,
    required double sensorTemperatureCelsius,
    String? darkFramesDirectory,
  }) {
    final gate = Completer<DefectMapStatus>();
    buildGates.add(gate);
    return gate.future;
  }

  @override
  Future<void> apply({
    required String cameraId,
    required bool applyDuringCapture,
  }) async {
    calls.add('preference:$applyDuringCapture');
  }

  @override
  Future<DefectMapStatus?> getStatus({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
  }) async => currentStatus;

  @override
  Future<void> applyToSequencer({
    required String cameraId,
    required int width,
    required int height,
    required double sensorTemperatureCelsius,
    required bool enabled,
    required DefectMapMethod method,
    required DefectMapKernelSize kernel,
    required bool saveOriginal,
  }) async {
    calls.add('runtime:$enabled:${method.wireValue}:${kernel.diameter}');
  }
}

DefectMapStatus _status(int count) => DefectMapStatus(
  cameraId: 'camera',
  width: 100,
  height: 100,
  temperatureBucket: DefectMapTemperatureBucket.fromCelsius(-10),
  defectivePixelCount: count,
  lastRebuiltUnixSeconds: 0,
  applyDuringCapture: false,
  storedOnDisk: true,
);

void main() {
  test('nullable UI fields can be cleared independently', () {
    const initial = DefectMapUiState(
      statusMessage: 'finished',
      errorMessage: 'failed',
    );

    final withoutError = initial.copyWith(errorMessage: null);
    expect(withoutError.statusMessage, 'finished');
    expect(withoutError.errorMessage, isNull);

    final withoutStatus = initial.copyWith(statusMessage: null);
    expect(withoutStatus.statusMessage, isNull);
    expect(withoutStatus.errorMessage, 'failed');
  });

  test('old-host build completion cannot overwrite a new-host build', () async {
    late _SwitchingBackendNotifier backendNotifier;
    late _ControlledDefectMapService service;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) {
          return backendNotifier = _SwitchingBackendNotifier(
            ref,
            _MockBackend(),
          );
        }),
        defectMapServiceProvider.overrideWith((ref) {
          return service = _ControlledDefectMapService(ref);
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(backendProvider);
    final notifier = container.read(defectMapNotifierProvider.notifier);

    final first = notifier.build(
      cameraId: 'camera',
      darkFramePaths: const [],
      darkFramesDirectory: '/host-a/darks',
      sensorTemperatureCelsius: -10,
    );
    expect(service.buildGates, hasLength(1));
    expect(container.read(defectMapNotifierProvider).isBuilding, isTrue);

    backendNotifier.replaceWith(_MockBackend());
    expect(container.read(defectMapNotifierProvider).isBuilding, isFalse);

    final second = notifier.build(
      cameraId: 'camera',
      darkFramePaths: const [],
      darkFramesDirectory: '/host-b/darks',
      sensorTemperatureCelsius: -10,
    );
    expect(service.buildGates, hasLength(2));

    service.buildGates.first.complete(_status(11));
    await first;
    expect(
      container.read(defectMapNotifierProvider).isBuilding,
      isTrue,
      reason: 'the old completion must not clear host B busy state',
    );
    expect(
      container.read(defectMapNotifierProvider).statusMessage,
      contains('/host-b/darks'),
    );

    service.buildGates.last.complete(_status(22));
    await second;
    final state = container.read(defectMapNotifierProvider);
    expect(state.isBuilding, isFalse);
    expect(state.errorMessage, isNull);
    expect(state.statusMessage, contains('22 defective pixels'));
  });

  test('an apply toggle does not orphan an in-flight build state', () async {
    late _ControlledDefectMapService service;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) {
          return _SwitchingBackendNotifier(ref, _MockBackend());
        }),
        defectMapServiceProvider.overrideWith((ref) {
          return service = _ControlledDefectMapService(ref);
        }),
      ],
    );
    addTearDown(container.dispose);
    final notifier = container.read(defectMapNotifierProvider.notifier);

    final build = notifier.build(
      cameraId: 'camera',
      darkFramePaths: const ['/dark-1.fits'],
      sensorTemperatureCelsius: -10,
    );
    await notifier.setApplyDuringCapture(cameraId: 'camera', apply: true);
    expect(container.read(defectMapNotifierProvider).isBuilding, isTrue);

    service.buildGates.single.complete(_status(33));
    await build;
    final state = container.read(defectMapNotifierProvider);
    expect(state.isBuilding, isFalse);
    expect(state.statusMessage, contains('33 defective pixels'));
  });

  test('missing current-bucket map cannot persist an enabled toggle', () async {
    late _ControlledDefectMapService service;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        allSettingsProvider.overrideWith((ref) => Stream.value(const {})),
        backendProvider.overrideWith((ref) {
          return _SwitchingBackendNotifier(ref, _MockBackend());
        }),
        defectMapServiceProvider.overrideWith((ref) {
          return service = _ControlledDefectMapService(ref);
        }),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(defectMapNotifierProvider.notifier)
        .setApplyDuringCapture(
          cameraId: 'camera',
          apply: true,
          width: 100,
          height: 100,
          sensorTemperatureCelsius: -10,
        );

    expect(service.calls, isEmpty);
    expect(
      container.read(defectMapNotifierProvider).errorMessage,
      contains('No defect map exists'),
    );
  });

  test('disabling clears runtime before persisting the preference', () async {
    late _ControlledDefectMapService service;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        allSettingsProvider.overrideWith((ref) => Stream.value(const {})),
        backendProvider.overrideWith((ref) {
          return _SwitchingBackendNotifier(ref, _MockBackend());
        }),
        defectMapServiceProvider.overrideWith((ref) {
          return service = _ControlledDefectMapService(ref);
        }),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(defectMapNotifierProvider.notifier)
        .setApplyDuringCapture(
          cameraId: 'camera',
          apply: false,
          width: 100,
          height: 100,
          sensorTemperatureCelsius: -10,
        );

    expect(service.calls, ['runtime:false:median:3', 'preference:false']);
  });

  test(
    'settings sync honors per-camera apply when auto-apply is off',
    () async {
      late _ControlledDefectMapService service;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          allSettingsProvider.overrideWith((ref) => Stream.value(const {})),
          backendProvider.overrideWith((ref) {
            return _SwitchingBackendNotifier(ref, _MockBackend());
          }),
          defectMapServiceProvider.overrideWith((ref) {
            return service = _ControlledDefectMapService(ref)
              ..currentStatus = DefectMapStatus(
                cameraId: 'camera',
                width: 100,
                height: 100,
                temperatureBucket: DefectMapTemperatureBucket.fromCelsius(-10),
                defectivePixelCount: 3,
                lastRebuiltUnixSeconds: 0,
                applyDuringCapture: true,
                storedOnDisk: true,
              );
          }),
        ],
      );
      addTearDown(container.dispose);
      await container.read(defectMapSettingsProvider.notifier).loaded;

      await container
          .read(defectMapNotifierProvider.notifier)
          .syncCurrentSettingsToSequencer(
            cameraId: 'camera',
            width: 100,
            height: 100,
            sensorTemperatureCelsius: -10,
          );

      expect(service.calls, ['runtime:true:median:3']);
    },
  );
}
