/// Selects the displayed frame's measurements, falling back to the most recent
/// measured frame while its Science results are pending. Ties retain the first
/// encountered frame. Rows without frame IDs are used only if none have IDs.
List<T> selectFrameScienceRows<T>(
  List<T> rows, {
  required int? capturedImageId,
  required int? Function(T) imageIdOf,
  required DateTime Function(T) timestampOf,
}) {
  if (rows.isEmpty) return <T>[];
  if (capturedImageId != null) {
    final matched = rows
        .where((row) => imageIdOf(row) == capturedImageId)
        .toList(growable: false);
    if (matched.isNotEmpty) return matched;
  }

  // A session has thousands of tiles per frame. Aggregate once per row rather
  // than rescanning the session for every tile during a UI build.
  final timestamps = <int, DateTime>{};
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  for (final row in rows) {
    final id = imageIdOf(row);
    if (id == null) continue;
    final timestamp = timestampOf(row);
    final previous = timestamps[id] ?? epoch;
    timestamps[id] = timestamp.isAfter(previous) ? timestamp : previous;
  }
  int? latestId;
  var latestTimestamp = epoch;
  for (final entry in timestamps.entries) {
    if (latestId == null || entry.value.isAfter(latestTimestamp)) {
      latestId = entry.key;
      latestTimestamp = entry.value;
    }
  }
  if (latestId == null) return rows;
  return rows
      .where((row) => imageIdOf(row) == latestId)
      .toList(growable: false);
}
