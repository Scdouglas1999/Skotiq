import 'dart:async';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

/// Staggers the primary, its optional mirror, and the independent fallback.
/// A slow mirror never extends the fallback's head start deadline. The first
/// successful response wins without abandoning other pending routes on failure.
/// The caller owns [client] and closes outstanding requests after this returns.
Future<http.Response> fetchFramingSurvey({
  required http.Client client,
  required Uri primary,
  required Uri fallback,
  Uri? primaryMirror,
  Duration mirrorDelay = const Duration(milliseconds: 600),
  Duration fallbackDelay = const Duration(seconds: 2),
  Duration timeout = const Duration(seconds: 30),
}) async {
  final result = Completer<http.Response>();
  final clock = Stopwatch()..start();
  final routes = [primary, if (primaryMirror != null) primaryMirror, fallback];
  final started = List.filled(routes.length, false);
  var failures = 0;
  late void Function(int) start;

  Future<void> request(int index) async {
    final uri = routes[index];
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
      if (index + 1 < routes.length) start(index + 1);
      if (failures == routes.length) result.completeError(error, stack);
    }
  }

  start = (index) {
    if (started[index] || result.isCompleted) return;
    started[index] = true;
    unawaited(request(index));
  };
  final timers = [
    if (primaryMirror != null) Timer(mirrorDelay, () => start(1)),
    Timer(fallbackDelay, () => start(routes.length - 1)),
  ];
  start(0);
  try {
    return await result.future;
  } finally {
    for (final timer in timers) {
      timer.cancel();
    }
  }
}
