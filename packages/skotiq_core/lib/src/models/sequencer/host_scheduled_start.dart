/// Parses the `at` field of the host's scheduled-start payload (the
/// `/api/night/scheduled-start` answers and the runtime channel).
DateTime? parseHostScheduledStart(Object? at) =>
    at is String && at.isNotEmpty ? DateTime.tryParse(at)?.toUtc() : null;
