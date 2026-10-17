import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/disconnected_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/session_provider.dart';
import 'package:skotiq_core/src/services/device_service.dart';

void main() {
  test(
    'active-profile focuser is not command authority while disconnected',
    () async {
      final backend = _FocuserBackend();
      final container = _container(
        backend,
        profile: const EquipmentProfileModel(
          name: 'Rig',
          focuserId: 'profile-focuser',
        ),
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(deviceServiceProvider).moveFocuserRelative(10),
        throwsA(isA<Exception>()),
      );

      expect(backend.relativeMoveCalls, 0);
    },
  );

  test('manual focuser moves are exclusive across callers', () async {
    final backend = _FocuserBackend(blockRelativeMove: true);
    final container = _container(backend);
    addTearDown(container.dispose);
    _connectFocuser(container);
    final service = container.read(deviceServiceProvider);

    final firstMove = service.moveFocuserRelative(25);
    await backend.relativeMoveStarted.future;

    await expectLater(
      service.moveFocuserRelative(10),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('already in progress'),
        ),
      ),
    );
    expect(backend.relativeMoveCalls, 1);

    backend.releaseRelativeMove.complete();
    await firstMove;
    expect(container.read(focuserStateProvider).position, 1025);
  });

  test('relative moves honor travel and driver increment limits', () async {
    final backend = _FocuserBackend(maxIncrement: 20, maxPosition: 1100);
    final container = _container(backend);
    addTearDown(container.dispose);
    _connectFocuser(container, maxPosition: 1100);
    final service = container.read(deviceServiceProvider);

    await expectLater(
      service.moveFocuserRelative(25),
      throwsA(isA<RangeError>()),
    );
    await expectLater(
      service.moveFocuserRelative(-1001),
      throwsA(isA<RangeError>()),
    );
    expect(backend.relativeMoveCalls, 0);
  });

  test(
    'absolute moves require absolute support and a valid position',
    () async {
      final backend = _FocuserBackend(maxPosition: 2000);
      final container = _container(backend);
      addTearDown(container.dispose);
      _connectFocuser(container, isAbsolute: false, maxPosition: 2000);
      final service = container.read(deviceServiceProvider);

      await expectLater(
        service.moveFocuserTo(1500),
        throwsA(isA<UnsupportedError>()),
      );
      expect(backend.absoluteMoveCalls, 0);

      final notifier = container.read(focuserStateProvider.notifier);
      notifier.setConnected(isAbsolute: true, maxPosition: 2000);
      await expectLater(
        service.moveFocuserTo(2001),
        throwsA(isA<RangeError>()),
      );
      expect(backend.absoluteMoveCalls, 0);
    },
  );

  test(
    'backend swap cancels stale verification but waits for move cleanup',
    () async {
      final backend = _FocuserBackend(blockRelativeMove: true);
      final container = _container(backend);
      addTearDown(container.dispose);
      _connectFocuser(container);
      final service = container.read(deviceServiceProvider);

      final move = service.moveFocuserRelative(25);
      await backend.relativeMoveStarted.future;
      var swapPrepared = false;
      final prepare = service.prepareForBackendSwap().then((_) {
        swapPrepared = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(swapPrepared, isFalse);

      backend.releaseRelativeMove.complete();
      await expectLater(move, throwsA(isA<StateError>()));
      await prepare;
      expect(swapPrepared, isTrue);
    },
  );

  test(
    'autofocus owns global session state until its real run settles',
    () async {
      final backend = _FocuserBackend(blockAutofocus: true);
      final container = _container(backend);
      addTearDown(container.dispose);
      _connectFocuser(container, isAbsolute: true);
      _connectCamera(container);
      final service = container.read(deviceServiceProvider);

      final firstRun = service.runAutofocus(
        exposureTime: 1,
        stepSize: 10,
        stepsOut: 3,
        useSettingsDefaults: false,
      );
      await backend.autofocusStarted.future;
      expect(container.read(sessionStateProvider).isAutofocusing, isTrue);

      await expectLater(
        service.runAutofocus(
          exposureTime: 1,
          stepSize: 10,
          stepsOut: 3,
          useSettingsDefaults: false,
        ),
        throwsA(isA<Exception>()),
      );
      expect(container.read(sessionStateProvider).isAutofocusing, isTrue);

      backend.releaseAutofocus.complete();
      await firstRun;
      expect(container.read(sessionStateProvider).isAutofocusing, isFalse);
    },
  );
}

ProviderContainer _container(
  SkotiqBackend backend, {
  EquipmentProfileModel? profile,
}) {
  return ProviderContainer(
    overrides: [
      backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
      activeEquipmentProfileProvider.overrideWithValue(profile),
    ],
  );
}

void _connectFocuser(
  ProviderContainer container, {
  bool isAbsolute = true,
  int maxPosition = 5000,
}) {
  container.read(focuserStateProvider.notifier)
    ..setConnecting('focuser-1', 'Focuser')
    ..setConnected(isAbsolute: isAbsolute, maxPosition: maxPosition)
    ..updatePosition(1000);
}

void _connectCamera(ProviderContainer container) {
  container.read(cameraStateProvider.notifier)
    ..setConnecting('camera-1', 'Camera')
    ..setConnected();
}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _FocuserBackend extends DisconnectedBackend {
  _FocuserBackend({
    this.blockRelativeMove = false,
    this.blockAutofocus = false,
    this.maxIncrement = 1000,
    this.maxPosition = 5000,
  });

  final bool blockRelativeMove;
  final bool blockAutofocus;
  final int maxIncrement;
  final int maxPosition;
  final relativeMoveStarted = Completer<void>();
  final releaseRelativeMove = Completer<void>();
  final autofocusStarted = Completer<void>();
  final releaseAutofocus = Completer<void>();
  var position = 1000;
  var moving = false;
  var relativeMoveCalls = 0;
  var absoluteMoveCalls = 0;

  @override
  Future<FocuserStatus> getFocuserStatus(String deviceId) async {
    return FocuserStatus(
      connected: true,
      position: position,
      moving: moving,
      maxPosition: maxPosition,
      stepSize: 1,
      isAbsolute: true,
      hasTemperature: false,
    );
  }

  @override
  Future<FocuserCapabilities?> getFocuserCapabilities(String deviceId) async {
    return FocuserCapabilities(
      maxPosition: maxPosition,
      maxIncrement: maxIncrement,
      absolute: true,
      canHalt: true,
    );
  }

  @override
  Future<void> focuserMoveRelative(String deviceId, int delta) async {
    relativeMoveCalls++;
    moving = true;
    if (!relativeMoveStarted.isCompleted) relativeMoveStarted.complete();
    if (blockRelativeMove) await releaseRelativeMove.future;
    position += delta;
    moving = false;
  }

  @override
  Future<void> focuserMoveTo(String deviceId, int target) async {
    absoluteMoveCalls++;
    position = target;
  }

  @override
  Future<AutofocusResult> autofocusStart({
    required String deviceId,
    required String cameraId,
    required double exposureTime,
    required int stepSize,
    required int stepsOut,
    String method = 'VCurve',
    int binning = 1,
    int? gain,
    int? offset,
    String curveFitting = 'Hyperbolic',
    int numberOfAttempts = 1,
    int exposuresPerPoint = 1,
    double rSquaredThreshold = 0.7,
    double outerCropRatio = 1.0,
    double innerCropRatio = 0.0,
    int useBrightestNStars = 0,
    int focuserSettleTimeMs = 500,
    String backlashCompMethod = 'Overshoot',
    int backlashIn = 350,
    int backlashOut = 0,
    int? measuredBacklashIn,
  }) async {
    if (!autofocusStarted.isCompleted) autofocusStarted.complete();
    if (blockAutofocus) await releaseAutofocus.future;
    return const AutofocusResult(
      bestPosition: 1000,
      bestHfr: 1.5,
      focusData: [],
      method: 'Hyperbolic',
      timestamp: 1,
      curveFitQuality: 0.95,
      backlashApplied: false,
    );
  }
}
