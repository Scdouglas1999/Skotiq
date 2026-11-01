/// The next instant, at or after [now], whose local wall clock reads
/// [hour]:[minute].
///
/// "Tomorrow" is the next calendar day, not 24 hours later: on a day with a
/// daylight-saving change those differ by an hour, and a time picked for after
/// the change would otherwise fire an hour early or late.
DateTime nextLocalTimeOfDay(DateTime now, int hour, int minute) {
  final local = now.toLocal();
  final today = DateTime(local.year, local.month, local.day, hour, minute);
  if (!today.isBefore(local)) return today;
  return DateTime(local.year, local.month, local.day + 1, hour, minute);
}
