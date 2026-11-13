import 'app_settings_state.g.dart';

/// How far a dither moves the guide star and when guiding counts as settled
/// after a dither or a start, as the guiding settings hold them. Every screen
/// that shows or uses these values reads them from here.
///
/// Distances are guide-camera pixels: PHD2 and the built-in guider both take
/// the settle threshold and the dither amount in pixels.
class GuideSettle {
  const GuideSettle({
    required this.pixels,
    required this.seconds,
    required this.timeoutSeconds,
    required this.ditherPixels,
    required this.ditherRaOnly,
  });

  /// The settings' values, each held to the range a guider accepts (the
  /// settings table's bounds).
  factory GuideSettle.of(AppSettingsState settings) => GuideSettle(
    pixels: AppSettingDefs.settleThreshold.clean(settings.settleThreshold),
    seconds: AppSettingDefs.settleTime.clean(settings.settleTime).toDouble(),
    timeoutSeconds: AppSettingDefs.settleTimeout
        .clean(settings.settleTimeout)
        .toDouble(),
    ditherPixels: ditherScalePixels(settings.ditherScale),
    ditherRaOnly: settings.ditherRaOnly,
  );

  /// The guide error, in pixels, below which guiding counts as settled.
  final double pixels;

  /// How long the error must stay below [pixels].
  final double seconds;

  /// How long to wait for that before giving up.
  final double timeoutSeconds;

  /// How far a dither moves the guide star, in pixels.
  final double ditherPixels;
  final bool ditherRaOnly;
}

/// The dither amount, in pixels, of the stored dither size.
double ditherScalePixels(String scale) => switch (scale) {
  'Small' => 2.0,
  'Large' => 10.0,
  _ => 5.0,
};

/// The stored dither size nearest to [pixels].
String ditherScaleFor(double pixels) {
  if (pixels < 3.5) return 'Small';
  if (pixels < 7.5) return 'Medium';
  return 'Large';
}
