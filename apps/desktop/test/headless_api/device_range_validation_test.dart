import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_desktop/headless_api/handlers/device_handlers.dart';
import 'package:skotiq_desktop/headless_api/validation.dart';
import 'package:shelf/shelf.dart';

/// Out-of-range device requests must be refused as bad requests, naming the
/// valid range, instead of reaching the driver and surfacing as
/// `500 internal_error`.
///
/// The cases come from real hardware on the Windows rig. Without the range
/// guard each one reaches the driver:
///   * filter slot 99 on an 8-slot ZWO EFW -> 500 internal_error carrying the
///     driver's own "Invalid position 99. Valid range: 0-7".
///   * filter name "NoSuchFilter" -> 500 internal_error carrying a Dart
///     "Invalid argument(s): ..." string.
///   * cooling target -300C / +999C on an ASI1600MM-Cool advertising -40..30 ->
///     200 {"status":"ok"}, with the impossible target reported back as the
///     live setpoint.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RangeBackend backend;
  late DeviceHandlers handlers;

  setUp(() {
    backend = _RangeBackend();
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    handlers = DeviceHandlers(container);
  });

  Request post(String path, Map<String, Object?> body) => Request(
    'POST',
    Uri.parse('http://localhost$path'),
    headers: {'content-type': 'application/json'},
    body: jsonEncode(body),
  );

  group('filter wheel slot range', () {
    test('a slot past the last one is refused, naming the range', () async {
      await expectLater(
        handlers.handleFilterWheelSetPosition(
          post('/api/filter-wheel/position', {
            'deviceId': 'native:zwo_efw:0',
            'position': 99,
          }),
        ),
        throwsA(
          isA<BadRequestError>()
              .having((BadRequestError e) => e.field, 'field', 'position')
              .having((BadRequestError e) => e.expected, 'expected', '0 to 7'),
        ),
      );
      expect(
        backend.positionCalls,
        isEmpty,
        reason: 'driver must not be called',
      );
    });

    test('the last valid slot is accepted', () async {
      final response = await handlers.handleFilterWheelSetPosition(
        post('/api/filter-wheel/position', {
          'deviceId': 'native:zwo_efw:0',
          'position': 7,
        }),
      );
      expect(response.statusCode, 200);
      expect(backend.positionCalls, [7]);
    });

    test('a wheel reporting no slot count is not second-guessed', () async {
      backend.filterCount = 0;
      final response = await handlers.handleFilterWheelSetPosition(
        post('/api/filter-wheel/position', {
          'deviceId': 'native:zwo_efw:0',
          'position': 42,
        }),
      );
      expect(response.statusCode, 200);
      expect(backend.positionCalls, [42]);
    });
  });

  group('filter wheel name lookup', () {
    test('an unknown name is refused and lists what is available', () async {
      await expectLater(
        handlers.handleFilterWheelSetByName(
          post('/api/filter-wheel/set-by-name', {
            'deviceId': 'native:zwo_efw:0',
            'name': 'NoSuchFilter',
          }),
        ),
        throwsA(
          isA<BadRequestError>()
              .having((BadRequestError e) => e.field, 'field', 'name')
              // Naming the real filters saves the caller a round trip.
              .having(
                (BadRequestError e) => e.message,
                'message',
                allOf(contains('Filter 1'), contains('Filter 8')),
              ),
        ),
      );
      expect(backend.nameCalls, isEmpty);
    });

    test('a known name still reaches the driver', () async {
      final response = await handlers.handleFilterWheelSetByName(
        post('/api/filter-wheel/set-by-name', {
          'deviceId': 'native:zwo_efw:0',
          'name': 'Filter 3',
        }),
      );
      expect(response.statusCode, 200);
      expect(backend.nameCalls, ['Filter 3']);
    });

    test('a wheel reporting no names is not second-guessed', () async {
      backend.filterNames = const [];
      final response = await handlers.handleFilterWheelSetByName(
        post('/api/filter-wheel/set-by-name', {
          'deviceId': 'native:zwo_efw:0',
          'name': 'Ha',
        }),
      );
      expect(response.statusCode, 200);
      expect(backend.nameCalls, ['Ha']);
    });
  });

  group('an unreadable bound must not fail the operation', () {
    // The range guards were added to stop bad input reaching the driver, not to
    // invent a new way for a valid request to fail. A status/capability read can
    // transiently fault on a USB-contended rig while the move itself would have
    // succeeded, so a failed read skips the guard rather than 500-ing.
    setUp(() => backend.throwOnReads = true);

    test('focuser move-to still reaches the driver', () async {
      final response = await handlers.handleFocuserMoveTo(
        post('/api/focuser/move-to', {
          'deviceId': 'ascom:Sim.Focuser',
          'position': 12345,
        }),
      );
      expect(response.statusCode, 200);
    });

    test('filter slot still reaches the driver', () async {
      final response = await handlers.handleFilterWheelSetPosition(
        post('/api/filter-wheel/position', {
          'deviceId': 'native:zwo_efw:0',
          'position': 3,
        }),
      );
      expect(response.statusCode, 200);
      expect(backend.positionCalls, [3]);
    });

    test('filter name still reaches the driver', () async {
      final response = await handlers.handleFilterWheelSetByName(
        post('/api/filter-wheel/set-by-name', {
          'deviceId': 'native:zwo_efw:0',
          'name': 'Ha',
        }),
      );
      expect(response.statusCode, 200);
      expect(backend.nameCalls, ['Ha']);
    });

    test('cooling target still reaches the driver', () async {
      final response = await handlers.handleCameraSetCooling(
        post('/api/camera/cooling', {
          'deviceId': 'native:zwo:0',
          'enabled': true,
          'targetTemp': -10.0,
        }),
      );
      expect(response.statusCode, 200);
      expect(backend.coolingCalls, [-10.0]);
    });
  });

  group('cooling setpoint range', () {
    test('an unreachably cold target is refused', () async {
      await expectLater(
        handlers.handleCameraSetCooling(
          post('/api/camera/cooling', {
            'deviceId': 'native:zwo:0',
            'enabled': true,
            'targetTemp': -300.0,
          }),
        ),
        throwsA(
          isA<BadRequestError>()
              .having((BadRequestError e) => e.field, 'field', 'targetTemp')
              .having(
                (BadRequestError e) => e.expected,
                'expected',
                '-40.0 to 30.0',
              ),
        ),
      );
      expect(backend.coolingCalls, isEmpty);
    });

    test('an unreachably warm target is refused', () async {
      await expectLater(
        handlers.handleCameraSetCooling(
          post('/api/camera/cooling', {
            'deviceId': 'native:zwo:0',
            'enabled': true,
            'targetTemp': 999.0,
          }),
        ),
        throwsA(
          isA<BadRequestError>().having(
            (BadRequestError e) => e.field,
            'field',
            'targetTemp',
          ),
        ),
      );
      expect(backend.coolingCalls, isEmpty);
    });

    test('a target inside the range is accepted', () async {
      final response = await handlers.handleCameraSetCooling(
        post('/api/camera/cooling', {
          'deviceId': 'native:zwo:0',
          'enabled': true,
          'targetTemp': -10.0,
        }),
      );
      expect(response.statusCode, 200);
      expect(backend.coolingCalls, [-10.0]);
    });

    test(
      'turning the cooler off without a target skips the range check',
      () async {
        // No targetTemp supplied: nothing to validate, and an operator must always
        // be able to switch the cooler off.
        final response = await handlers.handleCameraSetCooling(
          post('/api/camera/cooling', {
            'deviceId': 'native:zwo:0',
            'enabled': false,
          }),
        );
        expect(response.statusCode, 200);
        expect(backend.coolingCalls, [null]);
      },
    );

    test(
      'a camera advertising no cooling range is not second-guessed',
      () async {
        backend.coolerMinTempC = null;
        backend.coolerMaxTempC = null;
        final response = await handlers.handleCameraSetCooling(
          post('/api/camera/cooling', {
            'deviceId': 'native:zwo:0',
            'enabled': true,
            'targetTemp': -273.0,
          }),
        );
        expect(response.statusCode, 200);
        expect(backend.coolingCalls, [-273.0]);
      },
    );
  });
}

class _RangeBackend extends DisconnectedBackend {
  /// Make every status/capability read fault, as a flaky driver would.
  bool throwOnReads = false;
  int filterCount = 8;
  List<String> filterNames = const [
    'Filter 1',
    'Filter 2',
    'Filter 3',
    'Filter 4',
    'Filter 5',
    'Filter 6',
    'Filter 7',
    'Filter 8',
  ];
  double? coolerMinTempC = -40.0;
  double? coolerMaxTempC = 30.0;

  final List<int> positionCalls = [];
  final List<String> nameCalls = [];
  final List<double?> coolingCalls = [];

  @override
  Future<FocuserStatus> getFocuserStatus(String deviceId) async => throwOnReads
      ? throw StateError('driver poll faulted')
      : const FocuserStatus(
          connected: true,
          position: 26000,
          moving: false,
          maxPosition: 50000,
          stepSize: 20.0,
          isAbsolute: true,
          hasTemperature: false,
        );

  @override
  Future<void> focuserMoveTo(String deviceId, int position) async {}

  @override
  Future<FilterWheelStatus> getFilterWheelStatus(String deviceId) async =>
      throwOnReads
      ? throw StateError('driver poll faulted')
      : FilterWheelStatus(
          connected: true,
          position: 1,
          moving: false,
          filterCount: filterCount,
          filterNames: filterNames,
        );

  @override
  Future<void> filterWheelSetPosition(String deviceId, int position) async {
    positionCalls.add(position);
  }

  @override
  Future<void> filterWheelSetByName(String deviceId, String name) async {
    nameCalls.add(name);
  }

  @override
  Future<CameraCapabilities?> getCameraCapabilities(String deviceId) async =>
      throwOnReads
      ? throw StateError('driver poll faulted')
      : CameraCapabilities(
          maxWidth: 4656,
          maxHeight: 3520,
          bitDepth: 12,
          coolerMinTempC: coolerMinTempC,
          coolerMaxTempC: coolerMaxTempC,
        );

  @override
  Future<void> cameraSetCooling({
    required String deviceId,
    required bool enabled,
    double? targetTemp,
  }) async {
    coolingCalls.add(targetTemp);
  }
}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
