part of '../stack_and_share_models.dart';

/// Final result of a completed Stack-and-Share run. Persisted alongside the
/// session/target so a stacked master can be re-shared later.
class StackAndShareResult {
  /// Database id, if persisted.
  final int? id;

  /// Owning imaging session id, if any.
  final int? sessionId;

  /// Target id, if any.
  final int? targetId;

  /// Target name, denormalised for display.
  final String? targetName;

  /// Width of the integrated image in pixels.
  final int width;

  /// Height of the integrated image in pixels.
  final int height;

  /// Number of frames that made it into the integration.
  final int framesStacked;

  /// Number of frames the run attempted (stacked + rejected).
  final int framesAttempted;

  /// Total integration time of the stacked frames, in seconds.
  final double integrationSecs;

  /// Average alignment residual across stacked frames, in pixels.
  final double avgAlignmentResidual;

  /// Average HFR (half-flux radius) across stacked frames, if measured.
  final double? avgHfr;

  /// Filter of the stack, if mono / single-filter.
  final String? filter;

  /// Whether the integrated result is a colour (OSC/RGB) stack rather than a
  /// single-channel monochrome stack. Defaults to `false` (mono) so existing
  /// persisted results round-trip unchanged.
  final bool isColor;

  /// Channel count of the integrated result: `1` for a monochrome stack, `3`
  /// for an interleaved-RGB OSC stack. Defaults to `1`. Kept distinct from
  /// [isColor] so a future multi-channel layout (e.g. RGBA) is representable
  /// without overloading the boolean.
  final int channels;

  /// When the stack was produced.
  final DateTime createdAt;

  /// Path to the exported, share-ready image, if exported.
  final String? exportedImagePath;

  /// Underlying live-stacking statistics for the run.
  final LiveStackingStats stats;

  const StackAndShareResult({
    this.id,
    this.sessionId,
    this.targetId,
    this.targetName,
    required this.width,
    required this.height,
    required this.framesStacked,
    required this.framesAttempted,
    required this.integrationSecs,
    required this.avgAlignmentResidual,
    this.avgHfr,
    this.filter,
    this.isColor = false,
    this.channels = 1,
    required this.createdAt,
    this.exportedImagePath,
    this.stats = const LiveStackingStats(),
  });

  /// Number of frames rejected during the run.
  int get framesRejected =>
      (framesAttempted - framesStacked).clamp(0, framesAttempted);

  StackAndShareResult copyWith({
    int? id,
    int? sessionId,
    int? targetId,
    String? targetName,
    int? width,
    int? height,
    int? framesStacked,
    int? framesAttempted,
    double? integrationSecs,
    double? avgAlignmentResidual,
    double? avgHfr,
    String? filter,
    bool? isColor,
    int? channels,
    DateTime? createdAt,
    String? exportedImagePath,
    LiveStackingStats? stats,
  }) {
    return StackAndShareResult(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      targetId: targetId ?? this.targetId,
      targetName: targetName ?? this.targetName,
      width: width ?? this.width,
      height: height ?? this.height,
      framesStacked: framesStacked ?? this.framesStacked,
      framesAttempted: framesAttempted ?? this.framesAttempted,
      integrationSecs: integrationSecs ?? this.integrationSecs,
      avgAlignmentResidual: avgAlignmentResidual ?? this.avgAlignmentResidual,
      avgHfr: avgHfr ?? this.avgHfr,
      filter: filter ?? this.filter,
      isColor: isColor ?? this.isColor,
      channels: channels ?? this.channels,
      createdAt: createdAt ?? this.createdAt,
      exportedImagePath: exportedImagePath ?? this.exportedImagePath,
      stats: stats ?? this.stats,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StackAndShareResult &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          sessionId == other.sessionId &&
          targetId == other.targetId &&
          targetName == other.targetName &&
          width == other.width &&
          height == other.height &&
          framesStacked == other.framesStacked &&
          framesAttempted == other.framesAttempted &&
          integrationSecs == other.integrationSecs &&
          avgAlignmentResidual == other.avgAlignmentResidual &&
          avgHfr == other.avgHfr &&
          filter == other.filter &&
          isColor == other.isColor &&
          channels == other.channels &&
          createdAt == other.createdAt &&
          exportedImagePath == other.exportedImagePath &&
          stats == other.stats;

  @override
  int get hashCode => Object.hashAll([
    id,
    sessionId,
    targetId,
    targetName,
    width,
    height,
    framesStacked,
    framesAttempted,
    integrationSecs,
    avgAlignmentResidual,
    avgHfr,
    filter,
    isColor,
    channels,
    createdAt,
    exportedImagePath,
    stats,
  ]);
}
