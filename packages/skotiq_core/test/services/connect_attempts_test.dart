import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/device_service/connect_attempts.dart';

void main() {
  const id = 'sim_focuser_1';

  test('a Connected during the connect is the driver opening', () {
    final attempts = ConnectAttempts()..began(id);
    expect(attempts.onConnected(id), ConnectedMeaning.opened);
    expect(attempts.isOwn(id), isTrue);
    attempts.cameUp(id);
    expect(attempts.isOwn(id), isFalse);
    expect(attempts.onConnected(id), ConnectedMeaning.outside);
  });

  test('while a failed connect is being released its Connected is stale '
      'and its Disconnected is not a drop', () {
    final attempts = ConnectAttempts()
      ..began(id)
      ..failed(id, releasing: true);
    expect(attempts.onConnected(id), ConnectedMeaning.stale);
    expect(attempts.onDisconnected(id), isTrue);
    expect(attempts.onDisconnected(id), isFalse);
    attempts.dispose();
  });

  test('a Connected after a connect that failed without opening is that '
      'connect coming up late, once', () {
    final attempts = ConnectAttempts()
      ..began(id)
      ..failed(id, releasing: false);
    expect(attempts.isOwn(id), isTrue);
    expect(attempts.onConnected(id), ConnectedMeaning.late);
    expect(attempts.onConnected(id), ConnectedMeaning.outside);
    attempts.dispose();
  });

  test('a release that never reports back and a late window both end', () {
    fakeAsync((async) {
      final attempts = ConnectAttempts()
        ..began(id)
        ..failed(id, releasing: true);
      async.elapse(attempts.releaseWindow);
      expect(attempts.onDisconnected(id), isFalse);

      attempts
        ..began(id)
        ..failed(id, releasing: false);
      async.elapse(attempts.lateWindow);
      expect(attempts.isOwn(id), isFalse);
      expect(attempts.onConnected(id), ConnectedMeaning.outside);
    });
  });

  test('a Disconnected from before the connect in flight leaves it alone', () {
    final attempts = ConnectAttempts()..began(id);
    expect(attempts.onDisconnected(id), isFalse);
    expect(attempts.onConnected(id), ConnectedMeaning.opened);
  });
}
