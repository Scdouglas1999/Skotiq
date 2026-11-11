import 'package:flutter_riverpod/flutter_riverpod.dart';

/// On a remote client: the imaging host's scheduled start ("Start at dark") as
/// a UTC instant, or null when nothing is scheduled.
///
/// The schedule lives on the host, which starts the run itself, so it fires
/// whether or not a client is awake or connected at dark. Clients only mirror
/// it: from the host's `scheduledStart` runtime channel and from their own
/// arm and cancel requests.
final hostScheduledStartProvider = StateProvider<DateTime?>((ref) => null);

/// Parses the `at` field of the host's scheduled-start payload (the
/// `/api/night/scheduled-start` answers and the runtime channel).
DateTime? parseHostScheduledStart(Object? at) =>
    at is String && at.isNotEmpty ? DateTime.tryParse(at)?.toUtc() : null;
