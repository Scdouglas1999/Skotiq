/// Unix seconds (UTC), the way the tables in `schema/*.drift` store a
/// timestamp in an INTEGER column.
int toEpochSeconds(DateTime when) =>
    when.toUtc().millisecondsSinceEpoch ~/ 1000;

DateTime fromEpochSeconds(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
