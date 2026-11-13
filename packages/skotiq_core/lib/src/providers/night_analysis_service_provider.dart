import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'database_provider.dart';
import '../services/night_analysis_service.dart';

/// Riverpod provider for the Night Doctor. Constructor-injected DAOs mirror the
/// post-session services' idiom so tests override the DAO providers (or
/// construct the service directly) to run without native code.
final nightAnalysisServiceProvider = Provider<NightAnalysisService>((ref) {
  return NightAnalysisService(
    images: ref.watch(imagesDaoProvider),
    science: ref.watch(scienceDaoProvider),
    reports: ref.watch(nightReportsDaoProvider),
  );
});
