import 'dart:async';

/// One budget shared by a stage's sequential operations. A late reply cannot
/// start the next permission request or command after this budget expires.
class PositioningDeadline {
  PositioningDeadline(Duration duration) {
    _timer = Timer(duration, () {
      _expired = true;
      _elapsed.complete();
    });
  }

  final _elapsed = Completer<void>();
  late final Timer _timer;
  bool _expired = false;

  Future<T> run<T>(Future<T> Function() action) {
    if (_expired) return Future.error(TimeoutException('Location timed out'));
    return Future.any([
      action(),
      _elapsed.future.then<T>(
        (_) => throw TimeoutException('Location timed out'),
      ),
    ]);
  }

  void dispose() => _timer.cancel();
}
