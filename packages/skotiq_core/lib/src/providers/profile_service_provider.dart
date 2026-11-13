import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/profile_service.dart';

final profileServiceProvider = Provider<ProfileService>((ref) {
  return ProfileService(ref);
});
