part of '../science_provider.dart';

class SciencePhotometrySelectionNotifier
    extends AsyncNotifier<SciencePhotometrySelection> {
  static const _enabledKey = 'science.photometry.differential_active';
  static const _targetKey = 'science.photometry.target_anchor';
  static const _comparisonsKey = 'science.photometry.comparison_anchors';
  Future<void> _writeTail = Future<void>.value();

  @override
  Future<SciencePhotometrySelection> build() async {
    final settings = await _loadScienceSettingsMap(ref);
    final enabled = _parseBool(settings[_enabledKey], false);
    final target = _decodeAnchor(settings[_targetKey]);
    final comparisons = _decodeAnchors(settings[_comparisonsKey], maxItems: 8);

    return SciencePhotometrySelection(
      differentialEnabled: enabled,
      target: target,
      comparisons: comparisons,
    );
  }

  Future<void> _serialized(
    Future<void> Function(SciencePhotometrySelection current) operation,
  ) {
    final result = _writeTail.then((_) async {
      final current = state.valueOrNull;
      if (current == null) {
        throw StateError(
          'Science photometry selection is not loaded; refusing to '
          'overwrite it with defaults.',
        );
      }
      await operation(current);
    });
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> setDifferentialEnabled(bool enabled) =>
      _serialized((current) async {
        await _writeScienceSettings(ref, {_enabledKey: enabled.toString()});
        state = AsyncData(current.copyWith(differentialEnabled: enabled));
      });

  Future<void> setTarget(PhotometryAnchor? target) =>
      _serialized((current) async {
        final value = target == null ? '' : jsonEncode(target.toJson());
        final comparisons = current.comparisons
            .where((entry) => entry.objectId != target?.objectId)
            .toList(growable: false);

        await _writeScienceSettings(ref, {
          _targetKey: value,
          _comparisonsKey: jsonEncode(
            comparisons.map((entry) => entry.toJson()).toList(),
          ),
        });

        state = AsyncData(
          current.copyWith(
            target: target,
            clearTarget: target == null,
            comparisons: comparisons,
          ),
        );
      });

  Future<void> toggleComparison(
    PhotometryAnchor anchor, {
    int maxComparisons = 8,
  }) {
    return _serialized((current) async {
      final mutable = current.comparisons.toList(growable: true);

      final existingIndex = mutable.indexWhere(
        (entry) => entry.objectId == anchor.objectId,
      );
      if (existingIndex >= 0) {
        mutable.removeAt(existingIndex);
      } else if (mutable.length < maxComparisons) {
        mutable.add(anchor);
      }

      final filtered = mutable
          .where((entry) => entry.objectId != current.target?.objectId)
          .toList(growable: false);

      await _writeScienceSettings(ref, {
        _comparisonsKey: jsonEncode(
          filtered.map((entry) => entry.toJson()).toList(),
        ),
      });
      state = AsyncData(current.copyWith(comparisons: filtered));
    });
  }

  Future<void> clearComparisons() => _serialized((current) async {
    await _writeScienceSettings(ref, {_comparisonsKey: '[]'});
    state = AsyncData(current.copyWith(comparisons: const []));
  });

  Future<void> clearAll() => _serialized((_) async {
    await _writeScienceSettings(ref, {
      _enabledKey: 'false',
      _targetKey: '',
      _comparisonsKey: '[]',
    });
    state = const AsyncData(SciencePhotometrySelection());
  });

  bool _parseBool(String? value, bool fallback) {
    if (value == null || value.isEmpty) {
      return fallback;
    }
    switch (value.toLowerCase()) {
      case 'true':
        return true;
      case 'false':
        return false;
      default:
        throw FormatException('Invalid persisted boolean "$value"');
    }
  }

  PhotometryAnchor? _decodeAnchor(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return PhotometryAnchor.fromJson(decoded);
      }
      if (decoded is Map) {
        return PhotometryAnchor.fromJson(decoded.cast<String, dynamic>());
      }
      throw const FormatException('Target anchor must be a JSON object');
    } catch (error, stack) {
      developer.log(
        'SciencePhotometrySelectionNotifier: failed to decode target anchor '
        'from persisted JSON "$raw": $error',
        name: 'SciencePhotometrySelectionNotifier',
        level: 1000,
        error: error,
        stackTrace: stack,
      );
      Error.throwWithStackTrace(
        StateError('Persisted photometry target is corrupt: $error'),
        stack,
      );
    }
  }

  List<PhotometryAnchor> _decodeAnchors(String? raw, {int maxItems = 8}) {
    if (raw == null || raw.trim().isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw const FormatException('Comparison anchors must be a JSON list');
      }
      final anchors = <PhotometryAnchor>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          anchors.add(PhotometryAnchor.fromJson(item));
        } else if (item is Map) {
          anchors.add(PhotometryAnchor.fromJson(item.cast<String, dynamic>()));
        }
        if (anchors.length >= maxItems) {
          break;
        }
      }
      return anchors;
    } catch (error, stack) {
      developer.log(
        'SciencePhotometrySelectionNotifier: failed to decode comparison anchors '
        'from persisted JSON "$raw": $error',
        name: 'SciencePhotometrySelectionNotifier',
        level: 1000,
        error: error,
        stackTrace: stack,
      );
      Error.throwWithStackTrace(
        StateError('Persisted photometry comparisons are corrupt: $error'),
        stack,
      );
    }
  }
}

final sciencePhotometrySelectionProvider =
    AsyncNotifierProvider<
      SciencePhotometrySelectionNotifier,
      SciencePhotometrySelection
    >(SciencePhotometrySelectionNotifier.new);

final activePhotometryTargetObjectIdProvider = Provider<String>((ref) {
  final selection = ref.watch(sciencePhotometrySelectionProvider).valueOrNull;
  return selection?.target?.objectId ?? 'target_primary';
});

final scienceModeStateProvider = StateProvider<ScienceModeState>(
  (_) => const ScienceModeState(),
);

final scienceOverlayStateProvider = StateProvider<ScienceOverlayState>(
  (_) => const ScienceOverlayState(),
);
