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
