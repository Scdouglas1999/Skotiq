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
/// the inspector and the inline popover. Each range is wide enough for every
/// value an editor wrote before the editors shared it, so opening a saved
/// sequence never clamps one of its steps.
abstract final class NodeFieldLimits {
  static const ({double min, double max}) coolTargetC = (min: -50, max: 30);

  static const ({int min, int max}) loopRepeatCount = (min: 1, max: 9999);

  static const ({double min, double max}) delaySecs = (min: 0, max: 86400);

  static const ({double min, double max}) ditherPixels = (min: 0, max: 50);

  /// Settle limits of a Dither step and of a Start Guiding step, which write
  /// the same dither defaults.
  static const ({double min, double max}) settlePixels = (min: 0.1, max: 10);
  static const ({double min, double max}) settleSecs = (min: 1, max: 120);
  static const ({double min, double max}) settleTimeoutSecs = (
    min: 10,
    max: 300,
  );
}
