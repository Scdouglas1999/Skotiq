import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/smart_night/smart_night_draft_service.dart';
import 'database_provider.dart';

class SmartNightDraftLookup {
  final String profileId;
  final DateTime astronomicalDay;

  const SmartNightDraftLookup({
    required this.profileId,
    required this.astronomicalDay,
  });

  DateTime get _day => DateTime.utc(
    astronomicalDay.year,
    astronomicalDay.month,
    astronomicalDay.day,
  );

  @override
  bool operator ==(Object other) {
    return other is SmartNightDraftLookup &&
        other.profileId == profileId &&
        other._day == _day;
  }

  @override
  int get hashCode => Object.hash(profileId, _day);
}

final smartNightDraftServiceProvider = Provider<SmartNightDraftService>((ref) {
  return SmartNightDraftService(settingsDao: ref.watch(settingsDaoProvider));
});

final pendingSmartNightDraftProvider = FutureProvider.autoDispose
    .family<SmartNightDraft?, SmartNightDraftLookup>((ref, lookup) {
      return ref
          .watch(smartNightDraftServiceProvider)
          .loadPending(
            profileId: lookup.profileId,
            astronomicalDay: lookup.astronomicalDay,
          );
    });
