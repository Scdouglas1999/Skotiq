/// What an async operation started under, and whether that still holds.
///
/// Work that awaits the imaging host can finish after the user has linked to
/// a different host, closed the screen, or started the same load again. Its
/// result then belongs to nothing on screen and must be dropped. Capture a
/// scope before the first await and test [isCurrent] after each one:
///
/// ```dart
/// final scope = ref.backendScope(alive: () => mounted);
/// final frames = await scope.value.getSessionImages(id);
/// if (!scope.isCurrent) return;
/// setState(() => _frames = frames);
/// ```
///
/// [value] is the authority the scope was captured from: the backend, or a
/// host-data role such as an `ObservingListsStore`. Use it for every call the
/// operation makes, so a two-step write cannot land half on one host and half
/// on the next.
final class AsyncScope<T> {
  /// A scope over [value] that holds while [stillHolds] returns true.
  AsyncScope(this.value, bool Function() stillHolds) : _stillHolds = stillHolds;

  final T value;
  final bool Function() _stillHolds;

  /// False once the authority was replaced, the owner went away, or a newer
  /// scope superseded this one (see `AsyncScopes` in providers/).
  bool get isCurrent => _stillHolds();

  bool get isStale => !isCurrent;

  /// Throws when the scope is stale, for code whose caller shows the failure
  /// rather than dropping the result. [what] completes "... changed while
  /// (what)".
  void ensureCurrent(String what) {
    if (isCurrent) return;
    throw StateError(
      'The imaging host changed while $what. The stale result was '
      'discarded; try again on the current host.',
    );
  }

  /// Awaits [operation] and returns its result, or [ifStale] when the scope
  /// went stale meanwhile. An error from a stale operation is swallowed the
  /// same way, since nothing is left to show it to.
  Future<R> guard<R>(
    Future<R> Function(T value) operation, {
    required R ifStale,
  }) async {
    try {
      final result = await operation(value);
      return isCurrent ? result : ifStale;
    } on Object {
      if (isStale) return ifStale;
      rethrow;
    }
  }
}
