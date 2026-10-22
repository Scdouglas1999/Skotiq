import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shelf/shelf.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Runtime state the host shares with linked clients.
///
/// `GET /api/runtime/state` returns the latest value of every runtime channel
/// (plate solve, centering, autofocus result, the frame on screen), which a
/// client applies on connect and reconnect; live changes travel as
/// `HostRuntimeState` events. `POST /api/runtime/state` takes a value a client
/// computed itself for a channel that accepts reports, applies it to the
/// host's own providers so the host GUI shows it, and lets the host's
/// broadcast carry it to the other clients.
class RuntimeStateHandlers {
  RuntimeStateHandlers(this.container);

  final ProviderContainer container;

  Future<Response> handleGetState(Request request) async {
    // Reading the publisher makes sure it is listening on a headless host,
    // where no GUI watches it.
    container.read(hostRuntimeMirrorProvider);
    final updates = container.read(hostRuntimeStateStoreProvider).snapshot();
    return jsonOk({
      'updates': [for (final update in updates) update.toJson()],
    });
  }

  Future<Response> handleReport(Request request) async {
    final payload = await readJsonObject(request);
    final channel = requireString(payload, 'channel');
    final origin = requireString(payload, 'origin');
    final rawValue = payload['value'];
    if (rawValue != null && rawValue is! Map) {
      throw HandlerFailure(
        code: 'invalid_request',
        message: 'value must be an object or null',
        statusCode: 400,
      );
    }
    final applied = applyClientRuntimeReport(
      container,
      channel: channel,
      value: rawValue == null ? null : Map<String, dynamic>.from(rawValue),
      origin: origin,
    );
    if (!applied) {
      throw HandlerFailure(
        code: 'unknown_channel',
        message: 'The host does not accept reports for "$channel".',
        statusCode: 404,
      );
    }
    return jsonOk({'status': 'applied'});
  }
}
