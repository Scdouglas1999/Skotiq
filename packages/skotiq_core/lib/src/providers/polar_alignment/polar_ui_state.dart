part of '../polar_alignment_provider.dart';

// Polar alignment UI state (persisted — survives navigation & app restart)

/// Non-runtime UI preferences for the polar alignment screen.
///
/// Alignment phase and measurements live in [polarAlignmentStateProvider];
/// this holds mode, panel expansion, compact tab index, etc.
class PolarAlignmentUiState {
  const PolarAlignmentUiState({
    this.mode = PolarAlignmentMode.threePoint,
    this.showCommonSettings = false,
    this.showAdvancedSettings = false,
    this.showHistoryPanel = false,
    this.compactTabIndex = 1,
  });

  final PolarAlignmentMode mode;
  final bool showCommonSettings;
  final bool showAdvancedSettings;
  final bool showHistoryPanel;

  /// Selected tab in compact layout ([PolarAlignmentBodyLayout] < 700px).
  final int compactTabIndex;

  PolarAlignmentUiState copyWith({
    PolarAlignmentMode? mode,
    bool? showCommonSettings,
    bool? showAdvancedSettings,
    bool? showHistoryPanel,
    int? compactTabIndex,
  }) {
    return PolarAlignmentUiState(
      mode: mode ?? this.mode,
      showCommonSettings: showCommonSettings ?? this.showCommonSettings,
      showAdvancedSettings: showAdvancedSettings ?? this.showAdvancedSettings,
      showHistoryPanel: showHistoryPanel ?? this.showHistoryPanel,
      compactTabIndex: compactTabIndex ?? this.compactTabIndex,
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'showCommonSettings': showCommonSettings,
    'showAdvancedSettings': showAdvancedSettings,
    'showHistoryPanel': showHistoryPanel,
    'compactTabIndex': compactTabIndex,
  };

  factory PolarAlignmentUiState.fromJson(Map<String, dynamic> json) {
    final modeName = json['mode'] as String?;
    var mode = PolarAlignmentMode.threePoint;
    if (modeName != null) {
      for (final candidate in PolarAlignmentMode.values) {
        if (candidate.name == modeName) {
          mode = candidate;
          break;
        }
      }
    }

    final tabIndex = json['compactTabIndex'];
    return PolarAlignmentUiState(
      mode: mode,
      showCommonSettings: json['showCommonSettings'] as bool? ?? false,
      showAdvancedSettings: json['showAdvancedSettings'] as bool? ?? false,
      showHistoryPanel: json['showHistoryPanel'] as bool? ?? false,
      compactTabIndex: tabIndex is int ? tabIndex.clamp(0, 2) : 1,
    );
  }
}

/// Persisted UI state for the polar alignment screen.
final polarAlignmentUiStateProvider =
    StateNotifierProvider<PolarAlignmentUiStateNotifier, PolarAlignmentUiState>(
      (ref) {
        return PolarAlignmentUiStateNotifier(ref);
      },
    );

class PolarAlignmentUiStateNotifier
    extends StateNotifier<PolarAlignmentUiState> {
  PolarAlignmentUiStateNotifier(this.ref)
    : super(const PolarAlignmentUiState()) {
    _load();
  }

  final Ref ref;
  Future<void> _load() async {
    try {
      final db = ref.read(databaseProvider);
      final setting = await db.settingsDao.read(
        StoreSettings.polarAlignmentScreen,
      );
      if (setting != null) {
        final json = jsonDecode(setting) as Map<String, dynamic>;
        state = PolarAlignmentUiState.fromJson(json);
      }
    } catch (e) {
      Log.error(
        '[PolarAlignmentUiStateNotifier] Failed to load UI state: $e',
        source: 'PolarAlignmentUiStateNotifier',
        error: e,
      );
    }
  }

  Future<void> _persist() async {
    try {
      final db = ref.read(databaseProvider);
      await db.settingsDao.write(
        StoreSettings.polarAlignmentScreen,
        jsonEncode(state.toJson()),
      );
    } catch (e) {
      Log.error(
        '[PolarAlignmentUiStateNotifier] Failed to save UI state: $e',
        source: 'PolarAlignmentUiStateNotifier',
        error: e,
      );
    }
  }

  Future<void> setMode(PolarAlignmentMode mode) async {
    state = state.copyWith(mode: mode);
    await _persist();
  }

  Future<void> setShowCommonSettings(bool value) async {
    state = state.copyWith(showCommonSettings: value);
    await _persist();
  }

  Future<void> setShowAdvancedSettings(bool value) async {
    state = state.copyWith(showAdvancedSettings: value);
    await _persist();
  }

  Future<void> toggleHistoryPanel() async {
    state = state.copyWith(showHistoryPanel: !state.showHistoryPanel);
    await _persist();
  }

  Future<void> setCompactTabIndex(int index) async {
    state = state.copyWith(compactTabIndex: index.clamp(0, 2));
    await _persist();
  }
}

/// Maximum number of error samples to keep for visualization
const int _maxErrorHistorySamples = 60;

/// Provider for polar alignment error history (for real-time trend graph)
final polarAlignmentErrorHistoryProvider =
    StateNotifierProvider<
      PolarAlignmentErrorHistoryNotifier,
      List<PolarAlignmentError>
    >((ref) {
      return PolarAlignmentErrorHistoryNotifier();
    });

/// Notifier that maintains a rolling buffer of error measurements
class PolarAlignmentErrorHistoryNotifier
    extends StateNotifier<List<PolarAlignmentError>> {
  final Queue<PolarAlignmentError> _buffer = Queue<PolarAlignmentError>();

  PolarAlignmentErrorHistoryNotifier() : super([]);

  void addError(PolarAlignmentError error) {
    _buffer.add(error);
    if (_buffer.length > _maxErrorHistorySamples) {
      _buffer.removeFirst();
    }
    state = _buffer.toList();
  }

  void clear() {
    _buffer.clear();
    state = [];
  }
}
