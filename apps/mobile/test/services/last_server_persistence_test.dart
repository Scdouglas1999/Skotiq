import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/last_server_persistence.dart';

void main() {
  test('a direct host is saved while a relay tunnel is open', () {
    expect(
      shouldPersistConnectedServer(
        host: '192.168.1.20',
        port: 8080,
        tunnelHost: '127.0.0.1',
        tunnelPort: 4567,
      ),
      isTrue,
    );
  });

  test('the tunnel loopback endpoint is not saved as the last server', () {
    expect(
      shouldPersistConnectedServer(
        host: '127.0.0.1',
        port: 4567,
        tunnelHost: '127.0.0.1',
        tunnelPort: 4567,
      ),
      isFalse,
    );
  });

  test('loopback on a different port is not the tunnel endpoint', () {
    expect(
      shouldPersistConnectedServer(
        host: '127.0.0.1',
        port: 8080,
        tunnelHost: '127.0.0.1',
        tunnelPort: 4567,
      ),
      isTrue,
    );
  });

  test('no tunnel means the connected server is saved', () {
    expect(
      shouldPersistConnectedServer(
        host: '10.0.0.8',
        port: 8080,
        tunnelHost: null,
        tunnelPort: null,
      ),
      isTrue,
    );
  });
}
