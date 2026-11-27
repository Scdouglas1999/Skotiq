// Tonight's "now": one tick every night screen and the session providers
// read, so a test or a replay pins it in one place.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/providers.dart';

/// Now, as a true instant (UTC), on Tonight's shared 30 s tick.
///
/// Tests override this with a fixed instant.
final nightNowProvider = Provider<DateTime>((ref) {
  final tick = ref.watch(tickerProvider(TickerCadence.thirtySeconds));
  final now = tick.valueOrNull ?? ref.watch(clockProvider).nowUtc();
  return now.toUtc();
});

/// The session providers' "now": Tonight's [nightNowProvider] on the
/// operator's clock. Tests pin it.
final nightSessionNowProvider = Provider<DateTime>(
  (ref) => ref.watch(nightNowProvider).toLocal(),
);
