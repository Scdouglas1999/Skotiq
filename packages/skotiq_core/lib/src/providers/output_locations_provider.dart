import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/output_locations.dart';
import 'database_provider.dart';

/// [OutputLocations] for the capture folder setting, read when asked.
final outputLocationsProvider = FutureProvider.autoDispose<OutputLocations>(
  (ref) => OutputLocations.read(ref.watch(settingsDaoProvider)),
);

/// The folder a target's masters go into ([OutputLocations.mastersOf]).
final targetMastersFolderProvider = FutureProvider.autoDispose
    .family<Directory, String>(
      (ref, target) async =>
          (await ref.watch(outputLocationsProvider.future)).mastersOf(target),
    );
