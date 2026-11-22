/// Work that runs once and is shared, unless it fails.
///
/// The first [call] starts [compute]; later calls share that future while it
/// runs and after it succeeded. A failure is forgotten, so the next call runs
/// [compute] again.
class RetryableOnce<T> {
  RetryableOnce(this._compute);

  final Future<T> Function() _compute;
  Future<T>? _future;

  /// The run in progress or done; null before the first call and after a
  /// failure.
  Future<T>? get current => _future;

  Future<T> call() async {
    final future = _future ??= _compute();
    try {
      return await future;
    } on Object {
      if (identical(_future, future)) _future = null;
      rethrow;
    }
  }
}
