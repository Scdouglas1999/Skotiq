import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/logging_service.dart' show loggingServiceProvider;
import 'backend_provider.dart';
import 'settings_provider.dart';

/// Keeps this host's frame writer on the capture file format the settings
/// name, for manual captures and sequence frames alike. A linked client
/// writes no frames; its settings reach the host that does.
final captureFileFormatSyncProvider = Provider<void>((ref) {
  if (ref.watch(isRemoteClientProvider)) return;
  final choice = ref.watch(
    appSettingsProvider.select((s) {
      final settings = s.valueOrNull;
      if (settings == null) return null;
      return (
        format: normalizeCaptureImageFormat(settings.imageFormat),
        compression: normalizeXisfCompression(settings.xisfCompression),
        checksums: settings.xisfChecksums,
      );
    }),
  );
  // Settings not loaded yet: the writer keeps its default, FITS.
  if (choice == null) return;
  final backend = ref.watch(backendProvider);
  unawaited(
    backend
        .setCaptureFileFormat(
          format: choice.format,
          xisfCompression: choice.compression,
          xisfChecksums: choice.checksums,
        )
        .catchError((Object e) {
          ref
              .read(loggingServiceProvider)
              .error(
                'Captured frames keep their previous file format: $e',
                source: 'CaptureFileFormat',
              );
        }),
  );
});
