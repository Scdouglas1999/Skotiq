// A note at the top of a device's panel when the values below it are no
// longer being read: how old they are and the driver's reason. The values stay
// on screen, because the last position or temperature is still worth knowing,
// but never as if they were current.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../../localization/skotiq_localizations.dart';
import '../night_control_contracts.dart';
import 'panel_widgets.dart';

/// The stale-readings note for the [type] slot's [deviceId], or nothing.
class NightStaleReadingsNote extends ConsumerWidget {
  const NightStaleReadingsNote({
    super.key,
    required this.type,
    required this.deviceId,
  });

  final DeviceType type;
  final String? deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stale = ref.watch(staleReadingsProvider((type, deviceId)));
    if (stale == null) return const SizedBox.shrink();
    ref.watch(staleAgeTickerProvider);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: NightPanelNote(
        nightStaleReadingsText(SkotiqLocalizations.of(context), stale),
        tone: MetricTone.warning,
      ),
    );
  }
}

/// "Not updating: last read 3 min ago. Failed to get RA ...".
String nightStaleReadingsText(SkotiqLocalizations l10n, StaleReadings stale) {
  final age = stale.ageAt(DateTime.now());
  final reason = stale.reason?.trim();
  return l10n.text(
    age == null ? 'nightPanelStaleNoRead' : 'nightPanelStale',
    params: <String, String>{
      if (age != null) 'age': staleAgeText(age),
      'reason': reason == null || reason.isEmpty ? '' : ' $reason',
    },
  );
}
