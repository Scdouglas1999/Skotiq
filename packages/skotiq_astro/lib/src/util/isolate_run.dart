import 'dart:async';
import 'dart:isolate';

/// Runs [callback] with [message] on a short-lived isolate.
///
/// A top-level function so the closure handed to the isolate captures only
/// [callback] and [message], never the caller's surrounding state.
Future<R> runInIsolate<M, R>(FutureOr<R> Function(M) callback, M message) =>
    Isolate.run(() => callback(message));
