import 'dart:async';

import 'package:shelf/shelf.dart';

import 'package:skotiq_remote_protocol/wire.dart';

import 'response_helpers.dart';
import 'route_table.dart';

/// How long a request's handler may take before the server answers for it.
///
/// A handler that never finishes holds its connection forever: the client
/// gives up and closes its end, the server's end sits in CLOSE_WAIT, and under
/// polling load hundreds of them pile up until the host answers nobody. Every
/// request therefore gets an answer within its budget, even when the work
/// behind it cannot be cancelled.
///
/// Reads answer well inside a client's own timeout, so a read that takes a
/// minute has already been given up on. Commands may wait on the hardware (a
/// long exposure, a blind plate solve), so they get the longest single
/// exposure the app takes plus its download. Streams, WebSocket upgrades and
/// long polls hold their connection open by design and have no budget.
class HandlerTimeoutPolicy {
  const HandlerTimeoutPolicy({
    this.read = const Duration(seconds: 60),
    this.slowRead = const Duration(minutes: 10),
    this.command = const Duration(minutes: 65),
  });

  /// Budget for a GET or HEAD.
  final Duration read;

  /// Budget for a read that builds a file before answering (a backup, an
  /// export, a report).
  final Duration slowRead;

  /// Budget for every other method.
  final Duration command;

  /// The time a route of this class may take, or null for one that stays
  /// open by design.
  Duration? budgetFor(ApiTimeout timeout) => switch (timeout) {
    ApiTimeout.read => read,
    ApiTimeout.slowRead => slowRead,
    ApiTimeout.command => command,
    ApiTimeout.openEnded => null,
  };
}

/// Answers 503 for any request whose handler outlives its budget (see
/// [HandlerTimeoutPolicy]) and closes the connection, so a stuck handler
/// cannot hold a client's socket. [onTimeout] is told which request it was.
Middleware handlerTimeoutMiddleware({
  HandlerTimeoutPolicy policy = const HandlerTimeoutPolicy(),
  void Function(Request request, Duration budget)? onTimeout,
}) {
  return (innerHandler) {
    return (request) {
      final path = '/${request.url.path}';
      final budget = policy.budgetFor(RouteTable.of(request).policy.timeout);
      if (budget == null) return innerHandler(request);
      final answer = Future<Response>.sync(() => innerHandler(request));
      return answer.timeout(
        budget,
        onTimeout: () {
          onTimeout?.call(request, budget);
          // The handler keeps running; its eventual result or error has
          // nobody left to receive it.
          unawaited(answer.then((_) {}, onError: (Object _) {}));
          return jsonError(
            code: 'handler_timeout',
            message:
                'The imaging host did not finish ${request.method} $path '
                'within ${_describe(budget)}. It may be busy; try again.',
            statusCode: 503,
            headers: const {'connection': 'close', 'retry-after': '30'},
          );
        },
      );
    };
  };
}

String _describe(Duration d) =>
    d.inSeconds < 120 ? '${d.inSeconds} s' : '${d.inMinutes} min';
