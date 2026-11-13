import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/output_locations.dart';
import 'database_provider.dart';
import 'settings_provider.dart';

/// [OutputLocations] for the current capture folder setting.
final outputLocationsProvider = FutureProvider<OutputLocations>((ref) {
  ref.watch(appSettingsProvider.select((s) => s.valueOrNull?.imageOutputPath));
  return OutputLocations.read(ref.watch(settingsDaoProvider));
});

/// The folder a target's masters go into ([OutputLocations.mastersOf]).
final targetMastersFolderProvider = FutureProvider.family<Directory, String>(
  (ref, target) async =>
      (await ref.watch(outputLocationsProvider.future)).mastersOf(target),
);
