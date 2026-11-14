import 'dart:async';

import '../../../utils/resilient_poll_stream.dart';
import '../../../services/logging_service.dart';

/// Makes host data that has no change event watchable.
///
/// Each [watch] fetches when first listened to, again every `interval`, and
/// again right after [refresh] (which a remote role calls when this client has
/// just changed the data, so the change shows without waiting out the
/// interval). Listeners only see values that differ from the last one, and
/// once a value has been seen a failed fetch keeps it instead of erroring.
final class HostPoll {
  HostPoll(this.name);

  /// Names the data set in the log line for a retained fetch failure.
  final String name;

  static const defaultInterval = Duration(seconds: 10);

  final _refresh = StreamController<void>.broadcast();

  Stream<T> watch<T>(
    Future<T> Function() fetch,
    bool Function(T previous, T next) unchanged, {
    Duration interval = defaultInterval,
  }) => resilientDistinctPoll(
    fetch: fetch,
    unchanged: unchanged,
    interval: interval,
    refresh: _refresh.stream,
    onRetainedError: (error, stackTrace) {
      Log.warning(
        'Host poll for $name failed; keeping the last value',
        source: 'HostPoll',
        error: error,
        stackTrace: stackTrace,
      );
    },
  );

  /// Re-fetches every live [watch] now.
  void refresh() => _refresh.add(null);
}

/// One stream shared by every listener, with the last value replayed to
/// listeners that arrive later.
///
/// The source is opened by the first listener and cancelled when the last one
/// leaves; the last value is kept, so a listener that returns sees it at once
/// and then whatever the reopened source says differs from it.
final class SharedLatest<T> {
  SharedLatest(this._open, this._unchanged);

  final Stream<T> Function() _open;
  final bool Function(T previous, T next) _unchanged;

  final _listeners = <MultiStreamController<T>>{};
  StreamSubscription<T>? _source;
  late T _last;
  var _hasLast = false;
  (Object, StackTrace)? _pendingError;

  late final Stream<T> stream = Stream<T>.multi((listener) {
    if (_hasLast) {
      listener.addSync(_last);
    } else if (_pendingError case (final error, final stackTrace)) {
      listener.addErrorSync(error, stackTrace);
    }
    _listeners.add(listener);
    listener.onCancel = () {
      _listeners.remove(listener);
      if (_listeners.isNotEmpty) return null;
      final source = _source;
      _source = null;
      return source?.cancel();
    };
    _source ??= _open().listen(_onValue, onError: _onError);
  });

  void _onValue(T value) {
    if (_hasLast && _unchanged(_last, value)) return;
    _last = value;
    _hasLast = true;
    _pendingError = null;
    for (final listener in _listeners.toList()) {
      listener.add(value);
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    if (!_hasLast) _pendingError = (error, stackTrace);
    for (final listener in _listeners.toList()) {
      listener.addError(error, stackTrace);
    }
  }
}
