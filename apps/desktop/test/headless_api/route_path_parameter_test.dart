import 'package:flutter_test/flutter_test.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_desktop/headless_api/route_table.dart';
import 'package:skotiq_remote_protocol/wire.dart';

class _Routes implements RouteSource {
  const _Routes(this.routes);

  @override
  final Map<ApiEndpoint, Function> routes;
}

void main() {
  late List<String> received;
  late Handler handler;

  setUp(() {
    received = [];
    handler = RouteTable.only(
      _Routes({
        ImagingApi.clearDeviceImage: (Request request, String deviceId) {
          received.add(deviceId);
          return Response.ok('');
        },
      }),
    ).handler;
  });

  Future<Response> delete(String path) async =>
      handler(Request('DELETE', Uri.parse('http://localhost$path')));

  test(
    'a handler receives the value the client filled the route with',
    () async {
      const deviceId = 'indi:localhost:7624:CCD Simulator/1';
      final path = ImagingApi.clearDeviceImage.route.fill({
        'deviceId': deviceId,
      });

      await delete(path);

      expect(received, [deviceId]);
    },
  );

  test('a value written without encoding arrives unchanged', () async {
    await delete('/api/imaging/device-image/native:zwo:0');

    expect(received, ['native:zwo:0']);
  });
}
