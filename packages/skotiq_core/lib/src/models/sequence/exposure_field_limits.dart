/// The values an exposure's fields take, in every editor that sets them: the
/// inspector, the inline popover and a Smart Exposure plan. A limit changed
/// here is changed in all of them.
abstract final class ExposureFieldLimits {
  static const ({double min, double max}) durationSecs = (
    min: 0.001,
    max: 3600,
  );

  /// Frames an exposure step takes. A Smart Exposure plan may hold zero, which
  /// leaves its filter out.
  static const ({int min, int max}) frameCount = (min: 1, max: 9999);

  static const ({int min, int max}) gain = (min: 0, max: 1000);
  static const ({int min, int max}) offset = (min: 0, max: 1000);

  /// Frames between dithers; zero dithers never.
  static const ({int min, int max}) ditherEvery = (min: 0, max: 100);
}

/// The values the other step fields take, in every editor that sets them:
/// the inspector and the inline popover. Where the two editors allow
/// different ranges today, both are listed and named by editor.
abstract final class NodeFieldLimits {
  static const ({double min, double max}) coolTargetC = (min: -50, max: 30);

  static const ({int min, int max}) loopRepeatCount = (min: 1, max: 9999);

  static const ({double min, double max}) delaySecsInline = (
    min: 0,
    max: 86400,
  );
  static const ({double min, double max}) delaySecsInspector = (
    min: 0.1,
    max: 3600,
  );

  static const ({double min, double max}) ditherPixelsInline = (
    min: 0,
    max: 50,
  );
  static const ({double min, double max}) ditherPixelsInspector = (
    min: 1,
    max: 50,
  );

  /// Settle limits of a Dither step and of a Start Guiding step. Both write
  /// the same dither defaults.
  static const ({double min, double max}) ditherSettlePixels = (
    min: 0.1,
    max: 5,
  );
  static const ({double min, double max}) guidingSettlePixels = (
    min: 0.1,
    max: 10,
  );
  static const ({double min, double max}) ditherSettleSecs = (min: 5, max: 120);
  static const ({double min, double max}) guidingSettleSecs = (
    min: 1,
    max: 120,
  );
  static const ({double min, double max}) settleTimeoutSecs = (
    min: 10,
    max: 300,
  );
}
