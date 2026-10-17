// ignore_for_file: invalid_annotation_target

part of '../../sequence_models.dart';

/// Operating mode for a [LiveStackingNode].
///
/// `broadcastOnly` keeps the building stack in memory only. The
/// captured FITS files are untouched; the broadcast simply pulls a
/// rendered JPEG of the current stack on demand.
///
/// `recordAndBroadcast` additionally writes the stacked JPEG to the
/// session's save directory after every accepted frame so the user
/// keeps a build-up timelapse alongside the raw subs.
enum LiveStackingMode {
  broadcastOnly,
  recordAndBroadcast;

  String get storageKey => switch (this) {
    LiveStackingMode.broadcastOnly => 'broadcast_only',
    LiveStackingMode.recordAndBroadcast => 'record_and_broadcast',
  };

  String get label => switch (this) {
    LiveStackingMode.broadcastOnly => 'Broadcast only',
    LiveStackingMode.recordAndBroadcast => 'Record + broadcast',
  };

  static LiveStackingMode fromStorageKey(String? key) => switch (key) {
    'record_and_broadcast' => LiveStackingMode.recordAndBroadcast,
    _ => LiveStackingMode.broadcastOnly,
  };
}

/// Stack-combine method for the live stack.
///
/// Wire form is snake_case to match the Rust `StackMethod` enum
/// (see `native/skotiq_native/sequencer/src/lib.rs`).
enum LiveStackingMethod {
  average,
  medianRej,
  sigma;

  String get storageKey => switch (this) {
    LiveStackingMethod.average => 'average',
    LiveStackingMethod.medianRej => 'median_rej',
    LiveStackingMethod.sigma => 'sigma',
  };

  String get label => switch (this) {
    LiveStackingMethod.average => 'Average',
    LiveStackingMethod.medianRej => 'Median + Rejection',
    LiveStackingMethod.sigma => 'Sigma-clipped',
  };

  static LiveStackingMethod fromStorageKey(String? key) => switch (key) {
    'median_rej' => LiveStackingMethod.medianRej,
    'sigma' => LiveStackingMethod.sigma,
    _ => LiveStackingMethod.average,
  };
}

/// EAA / outreach broadcast node.
///
/// When entered, the node arms the broadcast service (a Rust singleton
/// shared with the Dart `BroadcastService`) and immediately returns
/// success. Sibling exposure nodes inside the same `Loop` / target
/// subtree continue to capture frames; each `FrameAccepted` event on
/// the backend feeds the saved FITS into the live-stacking engine and
/// publishes the result as a JPEG on the broadcast endpoint.
///
/// The instruction itself is non-blocking — a user dropping this node
/// in front of an `ExposureNode` does not have to wait on it. Stopping
/// the sequence (or starting a new one) automatically deactivates the
/// broadcast, so a paused public outreach run cannot leak imagery into
/// the next session.
class LiveStackingNode extends SequenceNode {
  /// Operating mode: broadcast only, or also write JPEG snapshots to
  /// disk for a built-up "timelapse" record.
  final LiveStackingMode mode;

  /// Stack-combine method (average / median+rej / sigma-clipped).
  final LiveStackingMethod stackMethod;

  /// Hard cap on number of frames added to the stack. `0` = unlimited.
  /// Long public events should set this so memory does not unbounded-
  /// grow over a multi-hour outreach session.
  final int maxFramesToStack;

  /// Whether the broadcast endpoint serves requests. Off => stack
  /// builds in memory but `/api/broadcast/live-stack` returns 404.
  final bool broadcastEnabled;

  /// TCP port for the broadcast endpoints. Defaults to 8081. Must
  /// not clash with the headless API server's port (validated by
  /// [LiveStackingPortClashRule] at edit time).
  final int broadcastPort;

  /// HTTP path prefix the broadcast HTML page is served at. Defaults
  /// to `/broadcast`. Useful for vanity URLs at public events.
  final String broadcastPath;

  /// Optional shared secret. When set (non-empty), every broadcast
  /// endpoint requires `?token=…` matching this value. `null` (or
  /// empty) = public access — appropriate for outreach but the
  /// settings UI defaults to private to make public an explicit
  /// opt-in.
  final String? authToken;

  /// Optional watermark text rendered on the broadcast JPEG. Variable
  /// interpolation is applied at render time so the user can
  /// write templates like `"M42 — L ${integration.hms}"`. `null`
  /// disables the watermark.
  final String? watermarkText;

  /// Output thumbnail width × height for the broadcast JPEG.
  /// Default 1280 × 720 keeps the payload phone-friendly while
  /// preserving enough detail for the EAA viewer.
  final int thumbnailWidth;
  final int thumbnailHeight;

  LiveStackingNode({
    super.id,
    super.name = 'Live Stacking',
    super.isEnabled,
    super.childIds = const [],
    super.parentId,
    super.orderIndex,
    super.comment,
    this.mode = LiveStackingMode.broadcastOnly,
    this.stackMethod = LiveStackingMethod.average,
    this.maxFramesToStack = 0,
    this.broadcastEnabled = true,
    this.broadcastPort = 8081,
    this.broadcastPath = '/broadcast',
    this.authToken,
    this.watermarkText,
    this.thumbnailWidth = 1280,
    this.thumbnailHeight = 720,
  });

  @override
  String get nodeType => 'LiveStacking';

  @override
  String get iconName => 'cast_connected';

  @override
  NodeCategory get category => NodeCategory.instruction;

  @override
  Set<DeviceType> get requiredDevices => const <DeviceType>{};

  /// True when the user has explicitly set a non-empty auth token.
  /// Used by the run-dashboard "Public" / "Private" badge.
  bool get isPublic => authToken == null || authToken!.isEmpty;

  /// True when a watermark template is configured.
  bool get hasWatermark =>
      watermarkText != null && watermarkText!.trim().isNotEmpty;

  @override
  LiveStackingNode copyWith({
    String? id,
    String? name,
    bool? isEnabled,
    List<String>? childIds,
    String? parentId,
    int? orderIndex,
    String? comment,
    LiveStackingMode? mode,
    LiveStackingMethod? stackMethod,
    int? maxFramesToStack,
    bool? broadcastEnabled,
    int? broadcastPort,
    String? broadcastPath,
    // Plain `?? this.X` for authToken and watermarkText. To clear back to
    // null (e.g. flipping a stream from private to public, or removing the
    // watermark) pass `clearAuthToken: true` / `clearWatermarkText: true`,
    // which win over the corresponding value arg and null the field.
    String? authToken,
    String? watermarkText,
    bool clearAuthToken = false,
    bool clearWatermarkText = false,
    int? thumbnailWidth,
    int? thumbnailHeight,
  }) {
    return LiveStackingNode(
      id: id ?? this.id,
      name: name ?? this.name,
      isEnabled: isEnabled ?? this.isEnabled,
      childIds: childIds ?? this.childIds,
      parentId: parentId ?? this.parentId,
      orderIndex: orderIndex ?? this.orderIndex,
      comment: comment ?? this.comment,
      mode: mode ?? this.mode,
      stackMethod: stackMethod ?? this.stackMethod,
      maxFramesToStack: maxFramesToStack ?? this.maxFramesToStack,
      broadcastEnabled: broadcastEnabled ?? this.broadcastEnabled,
      broadcastPort: broadcastPort ?? this.broadcastPort,
      broadcastPath: broadcastPath ?? this.broadcastPath,
      authToken: clearAuthToken ? null : (authToken ?? this.authToken),
      watermarkText: clearWatermarkText
          ? null
          : (watermarkText ?? this.watermarkText),
      thumbnailWidth: thumbnailWidth ?? this.thumbnailWidth,
      thumbnailHeight: thumbnailHeight ?? this.thumbnailHeight,
    );
  }

  @override
  List<Object?> get props => [
    ...super.props,
    mode,
    stackMethod,
    maxFramesToStack,
    broadcastEnabled,
    broadcastPort,
    broadcastPath,
    authToken,
    watermarkText,
    thumbnailWidth,
    thumbnailHeight,
  ];
}

/// Parse a duration string of the form "4h 30m", "90m", "3600s", "1.5h"
/// into seconds. Returns null for unparseable input. Used by the
/// integration-budget input on the SmartExposure properties editor.
///
/// Supported units (case-insensitive, may follow a number with or without
/// space): `s` (seconds), `m` (minutes), `h` (hours), `d` (days).
/// Multiple terms are summed: "1h 30m" → 5400. A bare number (no unit) is
/// interpreted as seconds for backwards compatibility with raw entry.
double? parseHumanDurationSecs(String input) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;

  // Bare number → seconds.
  final asNumber = double.tryParse(trimmed);
  if (asNumber != null) return asNumber;

  // Token scan: alternating (number, unit) pairs. Whitespace optional.
  final pattern = RegExp(r'(\d+(?:\.\d+)?)\s*([smhdSMHD])');
  final matches = pattern.allMatches(trimmed);
  if (matches.isEmpty) return null;

  double total = 0.0;
  for (final m in matches) {
    final value = double.tryParse(m.group(1) ?? '');
    final unit = m.group(2)?.toLowerCase();
    if (value == null || unit == null) return null;
    switch (unit) {
      case 's':
        total += value;
        break;
      case 'm':
        total += value * 60.0;
        break;
      case 'h':
        total += value * 3600.0;
        break;
      case 'd':
        total += value * 86400.0;
        break;
    }
  }
  return total;
}

/// Format a duration in seconds as a compact "Xh Ym" string. Used by the
/// integration-budget read-back in the properties editor and the Run
/// Dashboard's filter-integration panel.
String formatHumanDurationSecs(double secs) {
  if (secs <= 0) return '0s';
  final totalSecs = secs.round();
  final hours = totalSecs ~/ 3600;
  final minutes = (totalSecs % 3600) ~/ 60;
  final seconds = totalSecs % 60;
  if (hours > 0 && minutes > 0) return '${hours}h ${minutes}m';
  if (hours > 0) return '${hours}h';
  if (minutes > 0 && seconds > 0) return '${minutes}m ${seconds}s';
  if (minutes > 0) return '${minutes}m';
  return '${seconds}s';
}
