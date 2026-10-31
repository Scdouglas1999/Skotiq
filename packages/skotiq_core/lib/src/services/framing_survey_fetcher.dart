import 'dart:async';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

/// Lets the existing fallback compete with a slow primary without reducing the
/// requested image quality or abandoning a primary that may still succeed.
/// The caller owns [client] and closes outstanding requests after this returns.
Future<http.Response> fetchFramingSurvey({
  required http.Client client,
  required Uri primary,
  required Uri fallback,
  Duration fallbackDelay = const Duration(seconds: 2),
  Duration timeout = const Duration(seconds: 30),
}) async {
  final result = Completer<http.Response>();
  final clock = Stopwatch()..start();
  var fallbackStarted = false;
  var failures = 0;
  late void Function() startFallback;

  Future<void> request(Uri uri, {required bool isPrimary}) async {
    try {
      final response = await client.get(uri).timeout(timeout);
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw http.ClientException(
          'Survey returned HTTP ${response.statusCode} or an empty image',
          uri,
        );
      }
      if (!result.isCompleted) {
        developer.log(
          'Survey image from ${uri.host} in ${clock.elapsedMilliseconds}ms',
          name: 'FramingProvider',
        );
        result.complete(response);
      }
    } catch (error, stack) {
      if (result.isCompleted) return;
      developer.log(
        'Survey request to ${uri.host} failed: $error',
        name: 'FramingProvider',
        level: 900,
      );
      failures++;
      if (isPrimary) startFallback();
      if (failures == 2) result.completeError(error, stack);
    }
  }

  startFallback = () {
    if (fallbackStarted || result.isCompleted) return;
    fallbackStarted = true;
    unawaited(request(fallback, isPrimary: false));
  };
  final timer = Timer(fallbackDelay, startFallback);
  unawaited(request(primary, isPrimary: true));
  try {
    return await result.future;
  } finally {
    timer.cancel();
  }
}
