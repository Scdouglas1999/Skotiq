/// The rows a per-frame query last gave for a session, shown while another
/// frame's rows load, so a view keyed by frame does not blink empty each time
/// the frame changes.
class FrameRowsHold<T> {
  ({int sessionId, List<T> rows})? _shown;

  /// [loaded] when the query has answered, else the rows last shown for
  /// [sessionId], else none.
  List<T> rowsFor(int sessionId, List<T>? loaded) {
    if (loaded != null) {
      _shown = (sessionId: sessionId, rows: loaded);
      return loaded;
    }
    final shown = _shown;
    return shown != null && shown.sessionId == sessionId ? shown.rows : <T>[];
  }
}
