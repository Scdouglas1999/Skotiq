import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/providers/framing_image_cache_provider.dart';
import 'package:skotiq_core/src/providers/framing_provider.dart';
import 'package:skotiq_core/src/models/framing_models.dart';
import 'package:skotiq_core/src/services/framing_image_cache_service.dart';

class _NoPersistFramingNotifier extends FramingNotifier {
  _NoPersistFramingNotifier(super.ref);

  @override
  Future<void> persistLastFramedTarget(FramingTarget target) async {}
}

Future<String?> _imageErrorWith(
  Future<http.Response> Function(http.Request) handler,
) async {
  final tempDir = await Directory.systemTemp.createTemp('framing_offline_');
  addTearDown(() => tempDir.delete(recursive: true));
  final container = ProviderContainer(
    overrides: [
      framingImageCacheServiceProvider.overrideWithValue(
        FramingImageCacheService(supportDirProvider: () async => tempDir),
      ),
      framingProvider.overrideWith(_NoPersistFramingNotifier.new),
      framingSurveyHttpClientFactoryProvider.overrideWithValue(
        () => MockClient(handler),
      ),
    ],
  );
  addTearDown(container.dispose);
  final finished = Completer<void>();
  container.listen(framingProvider, (_, next) {
    if (!next.isLoadingImage &&
        next.imageError != null &&
        !finished.isCompleted) {
      finished.complete();
    }
  });
  container
      .read(framingProvider.notifier)
      .setTargetCoordinates(5.5879, -5.3897, name: 'M42');
  await finished.future.timeout(const Duration(seconds: 20));
  return container.read(framingProvider).imageError;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ux walk-2 F25: offline, a red box over the frame read "Error:
  // ClientException with SocketException: ... uri=https://skyview..." with
  // the whole request URL.
  test('offline, the survey failure is one plain sentence', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();

    final error = await _imageErrorWith(
      (_) => http.get(Uri.parse('http://127.0.0.1:$port/')),
    );

    expect(
      error,
      'Survey image unavailable: could not reach the survey servers.',
    );
  });

  test('a server refusal names the reason, not the request URL', () async {
    final error = await _imageErrorWith(
      (_) async => http.Response('Unavailable', 503),
    );

    expect(
      error,
      'Survey image unavailable: Survey returned HTTP 503 or an empty image',
    );
    expect(error, isNot(contains('http')));
  });
}
