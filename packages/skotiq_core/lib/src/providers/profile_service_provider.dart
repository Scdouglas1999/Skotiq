import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/profile_service.dart';
import 'linked_host.dart';

final profileServiceProvider = Provider<ProfileService>((ref) {
  return ProfileService(
    ref,
    hostProfiles: ref.watch(linkedHostProfilesProvider),
  );
});
