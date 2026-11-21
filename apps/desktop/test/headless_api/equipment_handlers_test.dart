import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_desktop/headless_api/handlers/equipment_handlers.dart';
import 'package:skotiq_desktop/headless_api/route_table.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:shelf/shelf.dart';

import 'handler_test_helpers.dart';

class _MockBackend extends Mock implements SkotiqBackend {}

void main() {
  group('EquipmentHandlers', () {
    late ProviderContainer container;
    late EquipmentHandlers handlers;

    setUp(() {
      container = ProviderContainer();
      handlers = EquipmentHandlers(container);
    });

    tearDown(() {
      container.dispose();
    });

    test(
      'status backend failures return JSON internal server errors',
      () async {
        final response = await translateHandlerErrors(
          handlers.handleCameraStatus(
            Request(
              'GET',
              Uri.parse('http://localhost/api/camera/status?deviceId=camera-1'),
            ),
          ),
        );

        expect(
          response.statusCode,
          anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
        );
        expect(response.headers['content-type'], 'application/json');
        final body = jsonDecode(await response.readAsString()) as Map;
        expect(body['error'], isA<String>());
      },
    );

    test(
      'capability backend failures return JSON internal server errors',
      () async {
        final capabilityHandlers = [
          handlers.handleCameraCapabilities,
          handlers.handleMountCapabilities,
          handlers.handleFocuserCapabilities,
          handlers.handleFilterWheelCapabilities,
          handlers.handleRotatorCapabilities,
        ];

        for (final handler in capabilityHandlers) {
          final response = await translateHandlerErrors(
            handler(
              Request(
                'GET',
                Uri.parse(
                  'http://localhost/api/equipment/capabilities'
                  '?deviceId=device-1',
                ),
              ),
            ),
          );

          expect(
            response.statusCode,
            anyOf(HttpStatus.badRequest, HttpStatus.internalServerError),
          );
          expect(response.headers['content-type'], 'application/json');
          final body = jsonDecode(await response.readAsString()) as Map;
          expect(body['error'], isA<String>());
        }
      },
    );

    test('health route decodes URL-encoded device IDs', () async {
      final backend = _MockBackend();
      when(
        () => backend.getDeviceHealth('native:zwo:0'),
      ).thenAnswer((_) async => (123, true));
      container.dispose();
      container = ProviderContainer(
        overrides: [deviceBackendProvider.overrideWithValue(backend)],
      );
      handlers = EquipmentHandlers(container);

      final response = await RouteTable.only(handlers).handler(
        Request(
          'GET',
          Uri.parse('http://localhost/api/device/health/native%3Azwo%3A0'),
        ),
      );

      expect(response.statusCode, HttpStatus.ok);
      verify(() => backend.getDeviceHealth('native:zwo:0')).called(1);
    });
    test('companions polling one device share a single driver read', () async {
      final backend = _MockBackend();
      var reads = 0;
      when(() => backend.getFocuserStatus('sim_focuser_1')).thenAnswer((
        _,
      ) async {
        reads++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return const FocuserStatus(
          connected: true,
          position: 25000,
          moving: false,
          maxPosition: 50000,
          stepSize: 1,
          isAbsolute: true,
          hasTemperature: false,
        );
      });
      var now = DateTime.utc(2026, 11, 1, 3);
      container.dispose();
      container = ProviderContainer(
        overrides: [deviceBackendProvider.overrideWithValue(backend)],
      );
      handlers = EquipmentHandlers(container, now: () => now);
      Request status() => Request(
        'GET',
        Uri.parse(
          'http://localhost/api/equipment/focuser/status?deviceId=sim_focuser_1',
        ),
      );

      final burst = await Future.wait([
        for (var i = 0; i < 8; i++) handlers.handleFocuserStatus(status()),
      ]);
      expect(burst.every((r) => r.statusCode == HttpStatus.ok), isTrue);
      expect(reads, 1);

      now = now.add(EquipmentHandlers.statusShareWindow);
      final later = await handlers.handleFocuserStatus(status());
      final body = jsonDecode(await later.readAsString()) as Map;
      expect(body['position'], 25000);
      expect(reads, 2);
    });

    // A slave read the focuser, moved it and read it again to confirm; the
    // second read was answered with the first and the slave reported a stall.
    test('a read after a device change is not answered from before it', () async {
      final backend = _MockBackend();
      var position = 24000;
      var reads = 0;
      when(() => backend.getFocuserStatus('sim_focuser_1')).thenAnswer((
        _,
      ) async {
        reads++;
        return FocuserStatus(
          connected: true,
          position: position,
          moving: false,
          maxPosition: 50000,
          stepSize: 1,
          isAbsolute: true,
          hasTemperature: false,
        );
      });
      final now = DateTime.utc(2026, 11, 7, 16);
      container.dispose();
      container = ProviderContainer(
        overrides: [deviceBackendProvider.overrideWithValue(backend)],
      );
      handlers = EquipmentHandlers(container, now: () => now);
      Future<int> readPosition() async {
        final response = await handlers.handleFocuserStatus(
          Request(
            'GET',
            Uri.parse(
              'http://localhost/api/equipment/focuser/status?deviceId=sim_focuser_1',
            ),
          ),
        );
        final body = jsonDecode(await response.readAsString()) as Map;
        return body['position'] as int;
      }

      expect(await readPosition(), 24000);
      position = 24500;
      handlers.forgetSharedStatus();

      expect(await readPosition(), 24500);
      expect(reads, 2);
    });

    test('a fresh focuser status read updates the connected card', () async {
      final backend = _MockBackend();
      when(() => backend.getFocuserStatus('focus')).thenAnswer(
        (_) async => const FocuserStatus(
          connected: true,
          position: 45350,
          moving: false,
          temperature: 17.5,
          maxPosition: 100000,
          stepSize: 1,
          isAbsolute: true,
          hasTemperature: true,
        ),
      );
      container.dispose();
      container = ProviderContainer(
        overrides: [deviceBackendProvider.overrideWithValue(backend)],
      );
      handlers = EquipmentHandlers(container);
      final focuser = container.read(focuserStateProvider.notifier);
      focuser.setConnecting('focus');
      focuser.setConnected();
      focuser.updatePosition(45360);

      final response = await handlers.handleFocuserStatus(
        Request(
          'GET',
          Uri.parse(
            'http://localhost/api/equipment/focuser/status?deviceId=focus',
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      final card = container.read(focuserStateProvider);
      expect(card.position, 45350);
      expect(card.temperature, 17.5);
      expect(card.isMoving, isFalse);

      when(() => backend.getFocuserStatus('other')).thenAnswer(
        (_) async => const FocuserStatus(
          connected: true,
          position: 1,
          moving: true,
          maxPosition: 100000,
          stepSize: 1,
          isAbsolute: true,
          hasTemperature: false,
        ),
      );
      await handlers.handleFocuserStatus(
        Request(
          'GET',
          Uri.parse(
            'http://localhost/api/equipment/focuser/status?deviceId=other',
          ),
        ),
      );
      expect(container.read(focuserStateProvider).position, 45350);

      focuser.updatePosition(45370);
      await handlers.handleFocuserStatus(
        Request(
          'GET',
          Uri.parse(
            'http://localhost/api/equipment/focuser/status?deviceId=focus',
          ),
        ),
      );
      expect(container.read(focuserStateProvider).position, 45370);
    });

    test('a fresh filter-wheel status read updates the current filter', () async {
      final backend = _MockBackend();
      when(() => backend.getFilterWheelStatus('wheel')).thenAnswer(
        (_) async => const FilterWheelStatus(
          connected: true,
          position: 1,
          moving: false,
          filterCount: 3,
          filterNames: ['L', 'R', 'G'],
        ),
      );
      container.dispose();
      container = ProviderContainer(
        overrides: [deviceBackendProvider.overrideWithValue(backend)],
      );
      handlers = EquipmentHandlers(container);
      final wheel = container.read(filterWheelStateProvider.notifier);
      wheel.setConnecting('wheel');
      wheel.setConnected();
      wheel.updatePosition(2);

      final response = await handlers.handleFilterWheelStatus(
        Request(
          'GET',
          Uri.parse(
            'http://localhost/api/equipment/filter-wheel/status?deviceId=wheel',
          ),
        ),
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(container.read(filterWheelStateProvider).currentFilterName, 'R');
    });
  });
}
