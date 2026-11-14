import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/night_end/night_end_settings.dart';

/// One line for the Darkroom header: what the end of the night will do.
final nightEndAutomationSummaryProvider = Provider.autoDispose<String?>((ref) {
  final settings = ref.watch(nightEndAutomationSettingsProvider).valueOrNull;
  if (settings == null) return null;
  final steps = settings.stepsOn;
  if (steps.isEmpty) return 'Night end: off';
  return 'Night end: ${steps.join(', ')}';
});

final nightEndAutomationActionsProvider = Provider(
  NightEndAutomationActions.new,
);
