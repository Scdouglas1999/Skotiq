import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockBackend extends Mock implements SkotiqBackend {}

void main() {
  group('readPhd2StatusOrDisconnected', () {
    test('returns disconnected status when host throws', () async {
      final backend = _MockBackend();
      when(() => backend.phd2GetStatus()).thenThrow(StateError('NotConnected'));

      final status = await readPhd2StatusOrDisconnected(backend);
      expect(status.connected, isFalse);
      expect(status.state, 'Disconnected');
    });
  });

  group('resolvePhd2ConnectHost', () {
    test('maps localhost and empty to 127.0.0.1', () {
      expect(resolvePhd2ConnectHost('localhost'), '127.0.0.1');
      expect(resolvePhd2ConnectHost('LOCALHOST'), '127.0.0.1');
      expect(resolvePhd2ConnectHost('::1'), '127.0.0.1');
      expect(resolvePhd2ConnectHost('  '), '127.0.0.1');
      expect(resolvePhd2ConnectHost('192.168.1.8'), '192.168.1.8');
    });
  });

  group('pollPhd2Connected', () {
    test('throws when PHD2 never reports connected', () async {
      final backend = _MockBackend();
      when(
        () => backend.phd2GetStatus(),
      ).thenAnswer((_) async => kPhd2DisconnectedStatus);

      await expectLater(
        pollPhd2Connected(
          backend,
          timeout: const Duration(milliseconds: 100),
          interval: const Duration(milliseconds: 25),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
