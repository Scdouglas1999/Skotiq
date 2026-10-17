// DeviceService switch-device tests.
//
// Mirrors the safety-monitor test coverage shape:
//   * connectSwitch happy path → backend called, state Connected
//   * connectSwitch rejects malformed device IDs up-front (format guard)
//   * connectSwitch error path resets state to Disconnected and rethrows
//   * disconnectSwitch on a connected device → backend called, state cleared
//   * SwitchStateNotifier basic CRUD (setConnecting / setConnected /
//     setDisconnected / setError / setAutoReconnect / setChannels)
//
// Follow-up adds per-channel UI coverage:
//   * refreshSwitchChannels polls get_max + per-channel name/state and
//     populates the snapshot
//   * setSwitchChannel writes via the bridge then mutates the cached
//     state; the bridge is called exactly once per toggle
//   * connectSwitch triggers an initial refresh (channel count + labels
//     land in the snapshot)
//
// The FFI branch in connectSwitch / refreshSwitchChannels /
// setSwitchChannel is normally guarded by `_backend is FfiBackend`,
// which MockBackend can't satisfy. We use
// `SwitchChannelService.switchBridgeBypassBackendCheck = true` to let
// the bridge function-pointer hooks (also overridden) stand in. The
// A-10 god-class split moved those hooks from `DeviceService` to
// `SwitchChannelService`; the public `DeviceService.refreshSwitchChannels`
// and `DeviceService.setSwitchChannel` methods are now thin delegators
// (see `services/switch_channel_service.dart`).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge_api;
import 'package:skotiq_core/src/backend/skotiq_backend.dart'
    hide CameraState;
import 'package:skotiq_core/src/models/equipment/equipment_models.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/services/device_exceptions.dart';
import 'package:skotiq_core/src/services/device_service.dart';
import 'package:skotiq_core/src/services/switch_channel_service.dart';

import '../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

/// Fakes wired into [SwitchChannelService.switchBridge*] for tests. Each list
/// is captured so individual cases can assert "called exactly once".
class _BridgeRecorder {
  final List<String> getMaxCalls = [];
  final List<(String, int)> getNameCalls = [];
  final List<(String, int)> getStateCalls = [];
  final List<(String, int, bool)> setStateCalls = [];
  final List<(String, int, double)> setValueCalls = [];

  /// Full capabilities are opt-in in legacy boolean tests; throwing here
  /// deliberately exercises the production fallback instead of touching the
  /// native bridge in the test process.
  bridge_api.SwitchCapabilities? capabilities;

  /// Number of channels the fake driver reports.
  int channelCount = 4;

  /// Per-channel labels returned by the fake `apiSwitchGetName`.
  List<String> labels = const ['12V Rail', 'Dew Strip', 'Camera', 'Mount'];

  /// Per-channel state returned by the fake `apiSwitchGetState`. Also
  /// the in-memory store for `apiSwitchSetState` writes.
  List<bool> states = [false, false, false, false];

  /// When non-null, `apiSwitchSetState` throws this exception. Used to
  /// exercise the "bridge error surfaces and state is NOT updated" path.
  Object? setStateError;

  void install() {
    SwitchChannelService.switchBridgeBypassBackendCheck = true;
    SwitchChannelService.switchBridgeGetMax = (deviceId) async {
      getMaxCalls.add(deviceId);
      return channelCount;
    };
    SwitchChannelService.switchBridgeGetName = (deviceId, switchId) async {
      getNameCalls.add((deviceId, switchId));
      return switchId < labels.length ? labels[switchId] : '';
    };
    SwitchChannelService.switchBridgeGetState = (deviceId, switchId) async {
      getStateCalls.add((deviceId, switchId));
      return switchId < states.length ? states[switchId] : false;
    };
    SwitchChannelService.switchBridgeSetState =
        (deviceId, switchId, state) async {
          setStateCalls.add((deviceId, switchId, state));
          if (setStateError != null) {
            throw setStateError!;
          }
          if (switchId < states.length) {
            states[switchId] = state;
          }
        };
    SwitchChannelService.switchBridgeGetCapabilities = (deviceId) async {
      final result = capabilities;
      if (result == null) {
        throw UnsupportedError('legacy boolean test fixture');
      }
      return result;
    };
    SwitchChannelService.switchBridgeSetValue =
        (deviceId, switchId, value) async {
          setValueCalls.add((deviceId, switchId, value));
        };
  }
}

void main() {
  late ProviderContainer container;
  late MockBackend mockBackend;
  late StreamController<SkotiqEvent> eventStreamController;
  late _BridgeRecorder bridge;

  setUpAll(() {
    registerMocktailFallbackValues();
  });

  setUp(() {
    mockBackend = MockBackend();
    eventStreamController = StreamController<SkotiqEvent>.broadcast();
    bridge = _BridgeRecorder()..install();

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

    // Initialize DeviceService so event listeners are active.
    container.read(deviceServiceProvider);
  });

  tearDown(() {
    eventStreamController.close();
    container.dispose();
    SwitchChannelService.resetHooks();
  });

  group('connectSwitch / disconnectSwitch', () {
    test('connectSwitch sets state to connected on backend success', () async {
      const deviceId = TestFixtures.switchId;

      when(
        () => mockBackend.connectDevice(DeviceType.switch_, deviceId),
      ).thenAnswer((_) async {});

      final service = container.read(deviceServiceProvider);
      await service.connectSwitch(deviceId);

      final state = container.read(switchStateProvider);
      expect(state.connectionState, DeviceConnectionState.connected);
      expect(state.deviceId, deviceId);

      verify(
        () => mockBackend.connectDevice(DeviceType.switch_, deviceId),
      ).called(1);
    });

    test('connectSwitch triggers an initial channel refresh', () async {
      const deviceId = TestFixtures.switchId;

      when(
        () => mockBackend.connectDevice(DeviceType.switch_, deviceId),
      ).thenAnswer((_) async {});
      bridge.channelCount = 3;
      bridge.labels = ['Dew Heater 1', 'Mount Power', 'Camera Power'];
      bridge.states = [true, false, true];

      final service = container.read(deviceServiceProvider);
      await service.connectSwitch(deviceId);

      final state = container.read(switchStateProvider);
      expect(state.connectionState, DeviceConnectionState.connected);
      expect(state.channelCount, 3);
      expect(
        state.channelNames,
        equals(['Dew Heater 1', 'Mount Power', 'Camera Power']),
      );
      expect(state.channelStates, equals([true, false, true]));
      expect(
        state.lastChannelRefresh,
        isNotNull,
        reason: 'Initial refresh must stamp the refresh timestamp.',
      );
      expect(bridge.getMaxCalls.single, deviceId);
      expect(bridge.getNameCalls, hasLength(3));
      expect(bridge.getStateCalls, hasLength(3));
    });

    test(
      'channel refresh failure does not undo a successful connection',
      () async {
        const deviceId = TestFixtures.switchId;
        when(
          () => mockBackend.connectDevice(DeviceType.switch_, deviceId),
        ).thenAnswer((_) async {});
        SwitchChannelService.switchBridgeGetCapabilities = (_) async =>
            throw StateError('capabilities unavailable');
        SwitchChannelService.switchBridgeGetMax = (_) async =>
            throw StateError('channel snapshot unavailable');

        await container.read(deviceServiceProvider).connectSwitch(deviceId);

        final state = container.read(switchStateProvider);
        expect(state.connectionState, DeviceConnectionState.connected);
        expect(state.deviceId, deviceId);
        expect(state.channelCount, 0);
      },
    );

    test(
      'connectSwitch throws InvalidDeviceIdException for malformed id',
      () async {
        // Format check rejects ids without a recognized driver
        // prefix. Backend must NOT be contacted.
        const deviceId = 'no-prefix-bare-id';

        final service = container.read(deviceServiceProvider);
        await expectLater(
          service.connectSwitch(deviceId),
          throwsA(
            isA<InvalidDeviceIdException>()
                .having((e) => e.deviceType, 'deviceType', 'switch')
                .having((e) => e.deviceId, 'deviceId', deviceId),
          ),
        );

        final state = container.read(switchStateProvider);
        expect(state.connectionState, DeviceConnectionState.disconnected);
        verifyNever(() => mockBackend.connectDevice(DeviceType.switch_, any()));
      },
    );

    test('connectSwitch resets state to disconnected and rethrows on backend '
        'failure', () async {
      const deviceId = TestFixtures.switchId;

      when(
        () => mockBackend.connectDevice(DeviceType.switch_, deviceId),
      ).thenThrow(Exception('Driver rejected connect'));

      final service = container.read(deviceServiceProvider);
      await expectLater(
        service.connectSwitch(deviceId),
        throwsA(isA<Exception>()),
      );

      final state = container.read(switchStateProvider);
      expect(state.connectionState, DeviceConnectionState.disconnected);
    });

    test('disconnectSwitch clears state when device was connected', () async {
      const deviceId = TestFixtures.switchId;

      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting(deviceId, 'Test Switch');
      notifier.setConnected();

      when(
        () => mockBackend.disconnectDevice(DeviceType.switch_, deviceId),
      ).thenAnswer((_) async {});

      final service = container.read(deviceServiceProvider);
      await service.disconnectSwitch();

      expect(
        container.read(switchStateProvider).connectionState,
        DeviceConnectionState.disconnected,
      );
      verify(
        () => mockBackend.disconnectDevice(DeviceType.switch_, deviceId),
      ).called(1);
    });

    test('disconnectSwitch throws DeviceNotConnectedException when no device '
        'was connected', () async {
      final service = container.read(deviceServiceProvider);
      await expectLater(
        service.disconnectSwitch(),
        throwsA(
          isA<DeviceNotConnectedException>().having(
            (e) => e.deviceType,
            'deviceType',
            'switch',
          ),
        ),
      );
      verifyNever(
        () => mockBackend.disconnectDevice(DeviceType.switch_, any()),
      );
    });
  });

  group('SwitchStateNotifier CRUD', () {
    test(
      'setConnecting + setConnected transitions through expected states',
      () {
        final notifier = container.read(switchStateProvider.notifier);

        expect(
          container.read(switchStateProvider).connectionState,
          DeviceConnectionState.disconnected,
        );

        notifier.setConnecting('native:switch:0', 'Test Switch');
        expect(
          container.read(switchStateProvider).connectionState,
          DeviceConnectionState.connecting,
        );
        expect(container.read(switchStateProvider).deviceId, 'native:switch:0');

        notifier.setConnected();
        expect(
          container.read(switchStateProvider).connectionState,
          DeviceConnectionState.connected,
        );
      },
    );

    test('setDisconnected preserves autoReconnectEnabled', () {
      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting('native:switch:0', 'Test');
      notifier.setConnected();
      notifier.setAutoReconnect(false);

      notifier.setDisconnected();

      final state = container.read(switchStateProvider);
      expect(state.connectionState, DeviceConnectionState.disconnected);
      expect(state.deviceId, isNull);
      expect(
        state.autoReconnectEnabled,
        isFalse,
        reason:
            'Auto-reconnect preference must persist across disconnects '
            '( contract).',
      );
    });

    test('setError moves state to error and stores DeviceError', () {
      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting('native:switch:0', 'Test');
      notifier.setConnected();

      notifier.setError(Exception('Bus timeout'));

      final state = container.read(switchStateProvider);
      expect(state.connectionState, DeviceConnectionState.error);
      expect(state.lastError, isNotNull);
      expect(state.lastError!.message, contains('Bus timeout'));
    });

    test('setChannels stores the channel snapshot', () {
      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting('native:switch:0', 'Test');
      notifier.setConnected();

      notifier.setChannels(
        count: 4,
        names: ['12V Rail', 'Dew Strip', 'Camera', 'Mount'],
        states: [true, false, true, true],
      );

      final state = container.read(switchStateProvider);
      expect(state.channelCount, 4);
      expect(state.channelNames, hasLength(4));
      expect(state.channelStates, hasLength(4));
      expect(state.channelNames[0], '12V Rail');
      expect(state.channelStates[1], isFalse);
      expect(state.channelStates[2], isTrue);
    });

    test('setChannelState mutates only the indexed channel', () {
      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting('native:switch:0', 'Test');
      notifier.setConnected();
      notifier.setChannels(
        count: 3,
        names: ['A', 'B', 'C'],
        states: [false, false, false],
      );

      notifier.setChannelState(1, true);

      final state = container.read(switchStateProvider);
      expect(state.channelStates, equals([false, true, false]));
    });

    test('setChannelState silently ignores out-of-range indices', () {
      // The UI must not be able to corrupt the cached snapshot by
      // requesting a channel that does not exist in `channelStates`.
      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting('native:switch:0', 'Test');
      notifier.setConnected();
      notifier.setChannels(count: 2, names: ['A', 'B'], states: [false, false]);

      notifier.setChannelState(5, true);
      notifier.setChannelState(-1, true);

      final state = container.read(switchStateProvider);
      expect(state.channelStates, equals([false, false]));
    });
  });

  group('refreshSwitchChannels', () {
    test('populates channel labels + states from the bridge', () async {
      const deviceId = TestFixtures.switchId;

      // Hand-build the connected state instead of routing through
      // connectSwitch so we exercise refreshSwitchChannels in
      // isolation.
      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting(deviceId, 'Test');
      notifier.setConnected();

      bridge.channelCount = 2;
      bridge.labels = ['Rail A', 'Rail B'];
      bridge.states = [true, false];

      final service = container.read(deviceServiceProvider);
      await service.refreshSwitchChannels();

      final state = container.read(switchStateProvider);
      expect(state.channelCount, 2);
      expect(state.channelNames, equals(['Rail A', 'Rail B']));
      expect(state.channelStates, equals([true, false]));
      expect(state.lastChannelRefresh, isNotNull);
    });

    test(
      'preserves analog ranges, values, descriptions and writeability',
      () async {
        const deviceId = TestFixtures.switchId;
        final notifier = container.read(switchStateProvider.notifier);
        notifier.setConnecting(deviceId, 'Test');
        notifier.setConnected();
        bridge.capabilities = const bridge_api.SwitchCapabilities(
          switchCount: 2,
          switches: [
            bridge_api.SwitchInfo(
              index: 0,
              name: 'Mount Power',
              description: '12V relay',
              isBoolean: true,
              minValue: 0,
              maxValue: 1,
              step: 1,
              canWrite: true,
              value: 1,
            ),
            bridge_api.SwitchInfo(
              index: 1,
              name: 'Dew Heater',
              description: 'PWM output',
              isBoolean: false,
              minValue: 0,
              maxValue: 100,
              step: 5,
              canWrite: false,
              value: 35,
            ),
          ],
        );

        await container.read(deviceServiceProvider).refreshSwitchChannels();

        final state = container.read(switchStateProvider);
        expect(state.channelNames, ['Mount Power', 'Dew Heater']);
        expect(state.channelDescriptions, ['12V relay', 'PWM output']);
        expect(state.channelIsBoolean, [true, false]);
        expect(state.channelValues, [1.0, 35.0]);
        expect(state.channelMinValues, [0.0, 0.0]);
        expect(state.channelMaxValues, [1.0, 100.0]);
        expect(state.channelSteps, [1.0, 5.0]);
        expect(state.channelCanWrite, [true, false]);
        expect(
          state.channelStates,
          [true, false],
          reason: 'Analog compact state uses the advertised range midpoint.',
        );
        expect(
          bridge.getMaxCalls,
          isEmpty,
          reason: 'A complete capability snapshot needs no legacy polling.',
        );
      },
    );

    test(
      'falls back to "" label when a per-channel name fetch fails',
      () async {
        // The provider+UI fall-back to "Channel N" labels for empty
        // strings, so we just need to verify the empty string is what
        // lands in the snapshot when the bridge throws on `get_name`.
        const deviceId = TestFixtures.switchId;
        final notifier = container.read(switchStateProvider.notifier);
        notifier.setConnecting(deviceId, 'Test');
        notifier.setConnected();

        bridge.channelCount = 2;
        SwitchChannelService.switchBridgeGetName = (deviceId, switchId) async {
          if (switchId == 0) throw StateError('driver lied');
          return 'Real Name';
        };

        final service = container.read(deviceServiceProvider);
        await service.refreshSwitchChannels();

        final state = container.read(switchStateProvider);
        expect(state.channelNames, equals(['', 'Real Name']));
      },
    );

    test('is a no-op when no switch is connected', () async {
      final service = container.read(deviceServiceProvider);
      await service.refreshSwitchChannels();
      expect(bridge.getMaxCalls, isEmpty);
    });
  });

  group('setSwitchChannel', () {
    test(
      'writes through to the bridge exactly once and updates state',
      () async {
        const deviceId = TestFixtures.switchId;
        final notifier = container.read(switchStateProvider.notifier);
        notifier.setConnecting(deviceId, 'Test');
        notifier.setConnected();
        notifier.setChannels(
          count: 2,
          names: ['Rail A', 'Rail B'],
          states: [false, false],
        );

        final service = container.read(deviceServiceProvider);
        await service.setSwitchChannel(0, true);

        expect(bridge.setStateCalls, equals([(deviceId, 0, true)]));
        expect(
          container.read(switchStateProvider).channelStates,
          equals([true, false]),
        );
      },
    );

    test('toggling off→on fires the bridge call exactly once', () async {
      const deviceId = TestFixtures.switchId;
      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting(deviceId, 'Test');
      notifier.setConnected();
      notifier.setChannels(count: 1, names: ['Rail'], states: [false]);

      final service = container.read(deviceServiceProvider);
      await service.setSwitchChannel(0, true);

      expect(
        bridge.setStateCalls,
        hasLength(1),
        reason:
            'A single user toggle must produce exactly one bridge '
            'write — no retries, no double-fires.',
      );
      expect(bridge.setStateCalls.single, (deviceId, 0, true));
      expect(container.read(switchStateProvider).channelStates.single, isTrue);
    });

    test('throws and does NOT mutate state when the bridge fails', () async {
      // A swallowed bridge failure would leave the channel state claiming a
      // hardware position that was never set.
      const deviceId = TestFixtures.switchId;
      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting(deviceId, 'Test');
      notifier.setConnected();
      notifier.setChannels(count: 1, names: ['Rail'], states: [false]);
      bridge.setStateError = StateError('relay stuck');

      final service = container.read(deviceServiceProvider);
      await expectLater(
        service.setSwitchChannel(0, true),
        throwsA(isA<StateError>()),
      );

      expect(
        container.read(switchStateProvider).channelStates.single,
        isFalse,
        reason:
            'A failed bridge write MUST NOT optimistically flip the '
            'cached state.',
      );
    });

    test(
      'throws DeviceNotConnectedException when no switch is connected',
      () async {
        final service = container.read(deviceServiceProvider);
        await expectLater(
          service.setSwitchChannel(0, true),
          throwsA(isA<DeviceNotConnectedException>()),
        );
        expect(bridge.setStateCalls, isEmpty);
      },
    );

    test('throws ArgumentError for out-of-range channelIndex', () async {
      const deviceId = TestFixtures.switchId;
      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting(deviceId, 'Test');
      notifier.setConnected();
      notifier.setChannels(count: 2, names: ['A', 'B'], states: [false, false]);

      final service = container.read(deviceServiceProvider);
      await expectLater(
        service.setSwitchChannel(5, true),
        throwsA(isA<ArgumentError>()),
      );
      expect(bridge.setStateCalls, isEmpty);
    });
  });

  group('setSwitchChannelValue', () {
    test(
      'writes an analog value once and reconciles the cached value',
      () async {
        const deviceId = TestFixtures.switchId;
        final notifier = container.read(switchStateProvider.notifier);
        notifier.setConnecting(deviceId, 'Test');
        notifier.setConnected();
        notifier.setChannels(
          count: 1,
          names: ['Dew Heater'],
          states: [false],
          isBoolean: [false],
          values: [25],
          minValues: [0],
          maxValues: [100],
          steps: [5],
          canWrite: [true],
        );

        await container
            .read(deviceServiceProvider)
            .setSwitchChannelValue(0, 55);

        expect(bridge.setValueCalls, [(deviceId, 0, 55.0)]);
        final state = container.read(switchStateProvider);
        expect(state.channelValues, [55.0]);
        expect(state.channelStates, [true]);
      },
    );

    test('rejects read-only analog channels before a hardware write', () async {
      const deviceId = TestFixtures.switchId;
      final notifier = container.read(switchStateProvider.notifier);
      notifier.setConnecting(deviceId, 'Test');
      notifier.setConnected();
      notifier.setChannels(
        count: 1,
        names: ['Input voltage'],
        states: [true],
        isBoolean: [false],
        values: [12.4],
        minValues: [0],
        maxValues: [15],
        steps: [0.1],
        canWrite: [false],
      );

      await expectLater(
        container.read(deviceServiceProvider).setSwitchChannelValue(0, 13),
        throwsUnsupportedError,
      );
      expect(bridge.setValueCalls, isEmpty);
    });
  });
}
