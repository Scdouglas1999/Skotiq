import 'dart:async';

import 'package:http/http.dart' as http;

import 'catalog_install_models.dart';

/// Wrap a catalog response body so a dead connection cannot hang the app.
///
/// Two failures a bare `await for` over the body cannot see:
///
/// * A stalled connection delivers no event, so there is no chunk to notice it
///   on. [idleTimeout] bounds the gap between chunks and raises
///   [CatalogDownloadStalled] when it is exceeded.
/// * A cancellation token read only inside the chunk handler is never reached
///   on a stalled transfer, which makes Cancel inert. [cancelPollInterval]
///   drives an independent poll.
///
/// Both terminate the transfer by erroring the returned stream.
Stream<List<int>> guardCatalogTransfer(
  Stream<List<int>> body, {
  required Duration idleTimeout,
  required Duration cancelPollInterval,
  Future<bool> Function()? isCancelled,
}) {
  final bounded = body.timeout(
    idleTimeout,
    onTimeout: (sink) {
      sink.addError(CatalogDownloadStalled(idleTimeout));
      sink.close();
    },
  );
  if (isCancelled == null) return bounded;

  final controller = StreamController<List<int>>();
  StreamSubscription<List<int>>? subscription;
  Timer? poll;
  var settled = false;
  var polling = false;

  void settle() {
    settled = true;
    poll?.cancel();
    poll = null;
  }

  controller.onListen = () {
    subscription = bounded.listen(
      controller.add,
      onError: (Object error, StackTrace stack) {
        settle();
        controller.addError(error, stack);
        controller.close();
      },
      onDone: () {
        settle();
        controller.close();
      },
    );
    poll = Timer.periodic(cancelPollInterval, (_) async {
      if (settled || polling) return;
      polling = true;
      try {
        final cancelled = await isCancelled();
        if (settled || !cancelled) return;
        settle();
        await subscription?.cancel();
        controller.addError(const CatalogCancelled());
        await controller.close();
      } catch (error, stack) {
        // A token that throws must fail the download, not become an
        // unhandled error in a timer nobody is awaiting.
        if (settled) return;
        settle();
        await subscription?.cancel();
        controller.addError(error, stack);
        await controller.close();
      } finally {
        polling = false;
      }
    });
  };
  controller.onPause = () => subscription?.pause();
  controller.onResume = () => subscription?.resume();
  controller.onCancel = () async {
    settle();
    await subscription?.cancel();
  };
  return controller.stream;
}

/// Open a catalog request under a bound, and let Cancel end the wait.
///
/// `Client.send` has no timeout of its own, so a host that accepts the socket
/// and never returns response headers would leave the download awaiting
/// forever, before any stream exists for [guardCatalogTransfer] to watch. The
/// GLADE+ query is the slow case: VizieR runs it for 20 s or more before the
/// first header, and a cancel pressed in that time used to wait it out.
///
/// The caller's `finally { client.close(); }` aborts the abandoned request.
Future<http.StreamedResponse> sendCatalogRequest(
  http.Client client,
  http.BaseRequest request, {
  required Duration timeout,
  required Duration cancelPollInterval,
  Future<bool> Function()? isCancelled,
}) {
  final response = client
      .send(request)
      .timeout(
        timeout,
        onTimeout: () => throw CatalogDownloadStalled(
          timeout,
          waitingFor: 'response headers',
        ),
      );
  if (isCancelled == null) return response;

  final result = Completer<http.StreamedResponse>();
  var polling = false;
  final poll = Timer.periodic(cancelPollInterval, (_) async {
    if (result.isCompleted || polling) return;
    polling = true;
    try {
      if (await isCancelled() && !result.isCompleted) {
        result.completeError(const CatalogCancelled());
      }
    } catch (error, stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    } finally {
      polling = false;
    }
  });
  response.then(
    (value) {
      if (!result.isCompleted) result.complete(value);
    },
    onError: (Object error, StackTrace stack) {
      if (!result.isCompleted) result.completeError(error, stack);
    },
  );
  return result.future.whenComplete(poll.cancel);
}
