// What Tonight shows about "Start at dark"; the schedule itself is
// `nightArmedStartProvider` in skotiq_core, which the host also serves to
// linked clients.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../services/observing_site.dart';

/// Tonight's astronomical dark (end of evening twilight) as a UTC instant;
/// null without a site or when the sun never gets that low.
final nightAstroDarkProvider = Provider<DateTime?>((ref) {
  return ref.watch(siteTwilightTimesProvider)?.astronomicalDusk?.toUtc();
});

/// The note an armed start carries: on the imaging host the app must stay
/// open; on a client the host starts the run whatever this computer does.
final armedStartNoteKeyProvider = Provider<String>(
  (ref) => ref.watch(backendProvider).remoteHost != null
      ? 'nightActArmedOnHost'
      : 'nightActArmedKeepOpen',
);
