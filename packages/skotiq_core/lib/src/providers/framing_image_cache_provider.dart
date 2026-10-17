import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/framing_image_cache_service.dart';
import 'framing_provider.dart' show SurveySource;

/// Canonical dependency-injection handle for [FramingImageCacheService].
///
/// Everything that reads or writes cached survey snapshots resolves the
/// service through this provider, so there is one instance and one on-disk
/// location. Tests override it with a service constructed via
/// `FramingImageCacheService(supportDirProvider: ...)` to redirect the cache
/// to a temporary directory.
final framingImageCacheServiceProvider = Provider<FramingImageCacheService>(
  (ref) => FramingImageCacheService(),
);

/// Family argument for [cachedSurveyImageFileProvider]: the target coordinates
/// and survey source identifying a single cached snapshot.
///
/// `raHours` is right ascension in **decimal hours** and `decDegrees` is
/// declination in **decimal degrees**, matching
/// [FramingImageCacheService.loadCachedSurveyImage] and the rest of the framing
/// subsystem (see `FramingTarget`/`Targets.ra`). A record is used so Riverpod
/// gets structural value equality for free, letting it cache and dedupe lookups
/// for the same target/source.
typedef CachedSurveyImageKey = ({
  double raHours,
  double decDegrees,
  SurveySource source,
});

/// Resolves the on-disk [File] for a previously-cached survey snapshot, or
/// `null` when no entry has been pinned for the requested target + source.
///
/// A thin read-through over [FramingImageCacheService.loadCachedSurveyImage]
/// with no fetch-or-fallback logic; the offline-first orchestration (cached
/// file versus network) lives in the framing notifier.
///
/// A genuine cache miss is a `null` value. IO failures while probing the cache
/// directory propagate as an [AsyncError], so a broken cache directory is not
/// reported as an empty one.
final cachedSurveyImageFileProvider =
    FutureProvider.family<File?, CachedSurveyImageKey>((ref, key) async {
      final service = ref.watch(framingImageCacheServiceProvider);
      return service.loadCachedSurveyImage(
        raHours: key.raHours,
        decDegrees: key.decDegrees,
        source: key.source,
      );
    });
