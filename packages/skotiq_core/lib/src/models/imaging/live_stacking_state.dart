import 'dart:typed_data';

import 'package:skotiq_astro/filters.dart';

import 'live_stacking_models.dart';

/// Live-stack filter keys in filter order ([compareFilterNames]), the stack
/// of unfiltered frames last.
int compareLiveStackFilters(String a, String b) {
  final aUnfiltered = a == kDefaultLiveStackFilterKey;
  final bUnfiltered = b == kDefaultLiveStackFilterKey;
  if (aUnfiltered != bUnfiltered) return aUnfiltered ? 1 : -1;
  return compareFilterNames(a, b);
}

/// Current state of the live stacking session.
enum LiveStackingStatus {
  /// No stacking session is active.
  idle,

  /// Stacking is active and processing frames.
  running,

  /// An error occurred during stacking.
  error,
}

/// Snapshot of one per-filter live stack slot.
class FilterStackSnapshot {
  final String filterKey;
  final LiveStackingStats stats;
  final Uint16List? previewData;
  final int previewWidth;
  final int previewHeight;
  final int channels;
  final int lastFrameSigmaRejectedPixels;
  final int lastFrameTotalPixels;
  final String? referenceImagePath;
  final int revision;
  final List<LiveStackFrameEvent> events;

  const FilterStackSnapshot({
    required this.filterKey,
    this.stats = const LiveStackingStats(),
    this.previewData,
    this.previewWidth = 0,
    this.previewHeight = 0,
    this.channels = 1,
    this.lastFrameSigmaRejectedPixels = 0,
    this.lastFrameTotalPixels = 0,
    this.referenceImagePath,
    this.revision = 0,
    this.events = const [],
  });

  bool get hasPixels =>
      previewData != null && previewWidth > 0 && previewHeight > 0;

  double get lastFrameSigmaRejectionRate {
    if (lastFrameTotalPixels <= 0) return 0.0;
    return lastFrameSigmaRejectedPixels / lastFrameTotalPixels;
  }

  double get totalIntegrationSecs => stats.totalIntegrationSecs;

  FilterStackSnapshot copyWith({
    LiveStackingStats? stats,
    Uint16List? previewData,
    bool clearPreviewData = false,
    int? previewWidth,
    int? previewHeight,
    int? channels,
    int? lastFrameSigmaRejectedPixels,
    int? lastFrameTotalPixels,
    String? referenceImagePath,
    bool clearReferenceImagePath = false,
    int? revision,
    List<LiveStackFrameEvent>? events,
  }) {
    return FilterStackSnapshot(
      filterKey: filterKey,
      stats: stats ?? this.stats,
      previewData: clearPreviewData ? null : (previewData ?? this.previewData),
      previewWidth: previewWidth ?? this.previewWidth,
      previewHeight: previewHeight ?? this.previewHeight,
      channels: channels ?? this.channels,
      lastFrameSigmaRejectedPixels:
          lastFrameSigmaRejectedPixels ?? this.lastFrameSigmaRejectedPixels,
      lastFrameTotalPixels: lastFrameTotalPixels ?? this.lastFrameTotalPixels,
      referenceImagePath: clearReferenceImagePath
          ? null
          : (referenceImagePath ?? this.referenceImagePath),
      revision: revision ?? this.revision,
      events: events ?? this.events,
    );
  }
}

/// Full state of the live stacking session for UI consumption.
class LiveStackingState {
  final LiveStackingStatus status;
  final LiveStackingStats stats;
  final LiveStackingConfig config;

  /// True when live stacking is armed to automatically capture and stack
  /// incoming frames (even before the first frame arrives to create a filter
  /// slot).
  final bool isArmed;

  /// Active per-filter live stacks keyed by normalized filter name (`L`, `Ha`,
  /// `OIII`, `Unfiltered`, ...).
  final Map<String, FilterStackSnapshot> filterStacks;

  /// The filter stack currently selected for preview, statistics, and Darkroom
  /// processing.
  final String? selectedFilterKey;

  /// Chronological (newest-first) log of evaluated frames across all filters.
  final List<LiveStackFrameEvent> frameLog;

  /// The most recent stacked preview image as u16 pixel data (mirrors the
  /// selected filter stack for backward compatibility with all existing viewers).
  final Uint16List? previewData;
  final int previewWidth;
  final int previewHeight;

  /// Sigma-clip pixels rejected on the most recently added frame.
  ///
  /// Derived from the cumulative total reported by Rust on each frame add:
  /// `stats.totalSigmaRejectedPixels - previous_total`. A spike in this value
  /// indicates a problem with the latest frame (clouds, satellite trail,
  /// drift, etc.) and is surfaced loudly in the UI.
  final int lastFrameSigmaRejectedPixels;

  /// Total pixel count of the most recently added frame. Captured from the
  /// stacker's output dimensions so the UI can compute a rejection rate
  /// (`lastFrameSigmaRejectedPixels / lastFrameTotalPixels`) without
  /// reaching back into [previewWidth]/[previewHeight] (which may be
  /// updated independently when a fresh preview is rendered).
  final int lastFrameTotalPixels;

  /// Error message if status == error.
  final String? errorMessage;

  /// On-disk path of the frame this stack is aligned to, when the session was
  /// started from a file.
  ///
  /// Every subsequent frame is registered onto this one, so the stack's pixel
  /// geometry IS this sub's — which is what lets a consumer resolve the
  /// stack's WCS, scale and orientation from the reference's own header
  /// instead of guessing them. Null when the stack was started from raw pixel
  /// data, when a remote host was armed without naming a reference, and
  /// whenever no stack is running.
  final String? referenceImagePath;

  const LiveStackingState({
    this.status = LiveStackingStatus.idle,
    this.stats = const LiveStackingStats(),
    this.config = const LiveStackingConfig(),
    this.isArmed = false,
    this.filterStacks = const {},
    this.selectedFilterKey,
    this.frameLog = const [],
    this.previewData,
    this.previewWidth = 0,
    this.previewHeight = 0,
    this.lastFrameSigmaRejectedPixels = 0,
    this.lastFrameTotalPixels = 0,
    this.errorMessage,
    this.referenceImagePath,
  });

  /// Sorted list of filter keys currently holding live stacks.
  List<String> get availableFilters {
    if (filterStacks.isEmpty) return const [];
    final keys = filterStacks.keys.toList(growable: false)
      ..sort(compareLiveStackFilters);
    return keys;
  }

  /// Currently selected filter stack snapshot, or null when none exist.
  FilterStackSnapshot? get activeFilterStack {
    if (filterStacks.isEmpty) return null;
    if (selectedFilterKey != null &&
        filterStacks.containsKey(selectedFilterKey)) {
      return filterStacks[selectedFilterKey];
    }
    return filterStacks[availableFilters.first];
  }

  /// The filter the live stack views show and act on: the selected one, else
  /// the first slot, else the unfiltered stack.
  String get viewedFilterKey =>
      selectedFilterKey ??
      activeFilterStack?.filterKey ??
      kDefaultLiveStackFilterKey;

  /// True when live stacking is running or armed for incoming frames.
  bool get isActiveOrArmed => status == LiveStackingStatus.running || isArmed;

  /// True when at least one stack has accumulated frames.
  bool get hasStackedFrames =>
      totalFramesAcrossFilters > 0 || stats.stackedFrameCount > 0;

  /// Total stacked frames across all active filter slots.
  int get totalFramesAcrossFilters {
    if (filterStacks.isEmpty) return stats.stackedFrameCount;
    var total = 0;
    for (final s in filterStacks.values) {
      total += s.stats.stackedFrameCount;
    }
    return total;
  }

  /// Total integration seconds across all active filter slots.
  double get totalIntegrationAcrossFilters {
    if (filterStacks.isEmpty) return stats.totalIntegrationSecs;
    var total = 0.0;
    for (final s in filterStacks.values) {
      total += s.stats.totalIntegrationSecs;
    }
    return total;
  }

  /// Per-frame sigma rejection rate (0.0 .. 1.0). Returns 0 when no frame
  /// has been processed yet to avoid divide-by-zero.
  double get lastFrameSigmaRejectionRate {
    if (lastFrameTotalPixels <= 0) return 0.0;
    return lastFrameSigmaRejectedPixels / lastFrameTotalPixels;
  }

  LiveStackingState copyWith({
    LiveStackingStatus? status,
    LiveStackingStats? stats,
    LiveStackingConfig? config,
    bool? isArmed,
    Map<String, FilterStackSnapshot>? filterStacks,
    String? selectedFilterKey,
    bool clearSelectedFilterKey = false,
    List<LiveStackFrameEvent>? frameLog,
    Uint16List? previewData,
    bool clearPreviewData = false,
    int? previewWidth,
    int? previewHeight,
    int? lastFrameSigmaRejectedPixels,
    int? lastFrameTotalPixels,
    String? errorMessage,
    bool clearErrorMessage = false,
    String? referenceImagePath,
    bool clearReferenceImagePath = false,
  }) {
    return LiveStackingState(
      status: status ?? this.status,
      stats: stats ?? this.stats,
      config: config ?? this.config,
      isArmed: isArmed ?? this.isArmed,
      filterStacks: filterStacks ?? this.filterStacks,
      selectedFilterKey: clearSelectedFilterKey
          ? null
          : (selectedFilterKey ?? this.selectedFilterKey),
      frameLog: frameLog ?? this.frameLog,
      previewData: clearPreviewData ? null : (previewData ?? this.previewData),
      previewWidth: previewWidth ?? this.previewWidth,
      previewHeight: previewHeight ?? this.previewHeight,
      lastFrameSigmaRejectedPixels:
          lastFrameSigmaRejectedPixels ?? this.lastFrameSigmaRejectedPixels,
      lastFrameTotalPixels: lastFrameTotalPixels ?? this.lastFrameTotalPixels,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
      referenceImagePath: clearReferenceImagePath
          ? null
          : (referenceImagePath ?? this.referenceImagePath),
    );
  }
}
