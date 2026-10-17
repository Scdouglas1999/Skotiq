import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/critical_alert_player.dart';

/// Riverpod provider for the [CriticalAlertPlayer] used by the Run
/// Dashboard critical-events bridge.
///
/// Production: returns a [CriticalAlertPlayer] which plays the platform
/// alert sound. Tests override with a capture-fake so they can assert how
/// many times the alert fired and with which sound choice.
final criticalAlertPlayerProvider = Provider<CriticalAlertPlayer>((ref) {
  return const CriticalAlertPlayer();
});
