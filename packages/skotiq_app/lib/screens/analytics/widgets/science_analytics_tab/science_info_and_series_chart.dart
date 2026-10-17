part of '../science_analytics_tab.dart';

// Science info explanations

const _kCalibrationInfo = '''
Photometric calibration is the process of converting raw pixel values in your images into standardized astronomical magnitudes. This lets you make scientifically meaningful brightness measurements rather than working with arbitrary intensity numbers.

When Skotiq plate-solves a frame, it identifies known stars in the field and compares their measured brightness (in pixel counts) against their cataloged magnitudes. This comparison produces a zero-point (ZP) — a single number that anchors your instrumental magnitudes to the standard magnitude scale.

A "Calibrated" status means Skotiq successfully matched enough catalog stars to compute a reliable zero-point. "Uncalibrated" means either the plate solve failed, too few stars were matched, or the fit residuals were too large to trust.

The zero-point value itself tells you about your system's overall sensitivity for this session. A higher ZP means your system is detecting fainter stars per unit of exposure time. Changes in ZP between sessions can indicate differences in sky conditions, optical cleanliness, or camera performance.
''';

const _kLimMagInfo = '''
Limiting magnitude (5-sigma) tells you the faintest star your imaging system can reliably detect in the current conditions, at a 5-sigma confidence level. In other words, a star at this magnitude would produce a signal five times stronger than the background noise — the standard threshold astronomers use to distinguish real detections from noise.

This is one of the most important single numbers for evaluating your imaging setup's performance on a given night. It combines the effects of your telescope's aperture, camera sensitivity, sky brightness, atmospheric transparency, tracking accuracy, and focus quality into a single metric.

A higher limiting magnitude means you're reaching fainter objects. Typical values for amateur setups range from magnitude 16 to 22 depending on equipment and conditions. Comparing this number across sessions helps you identify your best nights and track equipment performance over time.

The "matched stars" count shows how many catalog stars were used to compute this value. More matched stars generally means a more reliable measurement. Fewer than ~20 matched stars may indicate the value is less trustworthy.
''';

const _kTransparencyInfo = '''
Atmospheric transparency measures how much starlight makes it through the atmosphere without being absorbed or scattered. It's expressed as a percentage, where 100% would mean perfectly clear skies with zero atmospheric extinction beyond the minimum.

Skotiq estimates transparency by comparing the measured brightness of known stars against their expected catalog magnitudes, after accounting for your system's calibrated zero-point. If stars appear dimmer than expected, the atmosphere is absorbing some of the light.

The quality bucket (Clear, Thin Cloud, etc.) provides a quick human-readable assessment based on the transparency percentage. This helps you decide whether conditions are suitable for photometry, narrowband imaging, or if you should wait for clearer skies.

Transparency is distinct from "seeing" (which measures atmospheric turbulence and affects star sharpness). You can have excellent transparency with poor seeing, or vice versa. Both matter for imaging, but transparency is especially critical for photometric accuracy and reaching faint targets.
''';

const _kMovingObjectsInfo = '''
The moving object detector searches for sources that shift position between consecutive frames in your imaging session. This can reveal asteroids, comets, near-Earth objects (NEOs), or even artificial satellites passing through your field of view.

Skotiq compares the positions of detected sources across multiple exposures. Objects that show consistent linear motion (within expected velocity ranges for solar system objects) are flagged as candidates. Each candidate is assigned a confidence score based on how well its apparent motion fits expected trajectories and how clearly it stands out from noise or image artifacts.

The count shown here represents the number of distinct candidate objects found. A high count doesn't necessarily mean many real asteroids — some candidates may be hot pixels, cosmic ray hits, or other artifacts that mimic motion. The confidence percentage of the top candidate helps you gauge how likely the best detection is to be a real object.

If you detect a high-confidence moving object that doesn't match known solar system bodies, it could be a previously undiscovered asteroid — a genuinely exciting find that you can report to the Minor Planet Center (MPC).
''';

const _kDifferentialPhotometryInfo = '''
Differential photometry measures how a target object's brightness changes over time relative to stable comparison stars in the same field of view. By measuring the target and comparison stars simultaneously in each frame, most atmospheric and instrumental effects cancel out, enabling very precise brightness measurements.

The Y-axis shows differential magnitude (dMag) — the difference between the target star's magnitude and the comparison ensemble. The axis is inverted so that brighter values appear higher on the chart, following the astronomical convention where lower magnitude numbers mean brighter objects.

The error bars on each data point show the measurement uncertainty. Smaller error bars indicate more precise measurements. Factors that reduce uncertainty include longer exposures, better focus, higher transparency, and more comparison stars.

This chart is essential for detecting variable stars, transiting exoplanets, eclipsing binaries, and other objects that change brightness. An exoplanet transit, for example, would appear as a subtle dip (typically 0.005-0.02 magnitudes) lasting a few hours. Eclipsing binaries show deeper, more regular dips.

For the most accurate results, ensure your comparison stars are non-variable, similar in color to your target, and well-exposed without saturation.
''';

const _kTransparencyTrendInfo = '''
The transparency trend chart tracks how atmospheric clarity changes throughout your imaging session. Each point represents a transparency measurement derived from comparing measured star brightnesses to their catalog values.

A flat, high line (near 90-100%) indicates stable, clear conditions — ideal for photometry and deep imaging. A downward trend suggests increasing cloud cover, rising humidity, or the target moving to lower altitude where atmospheric extinction is greater.

Sudden drops usually indicate thin clouds passing through the field. Gradual declines over the session may reflect changing atmospheric conditions, increasing dew formation on optics, or the target descending toward the horizon.

This chart helps you identify which portions of your session had the best conditions, so you can selectively stack only the frames captured during optimal transparency. It's also useful for explaining unexpected scatter in your photometry data — periods of poor transparency will naturally produce noisier magnitude measurements.

The X-axis shows elapsed time from the start of the session in minutes.
''';

const _kPsfFieldMapInfo = '''
The PSF (Point Spread Function) Field Map shows how star sharpness varies across your imaging sensor. Each tile in the grid represents a region of the field of view, color-coded by the median FWHM (Full Width at Half Maximum) of stars detected in that region.

FWHM measures how spread out a star's light profile is, in pixels. A perfectly focused star on a sensor with no atmospheric distortion would be as small as the diffraction limit allows. In practice, FWHM is typically 2-6 pixels for amateur setups and is affected by focus accuracy, atmospheric seeing, optical aberrations, and tracking errors.

Green tiles indicate regions with tight, well-focused stars (low FWHM). Red tiles indicate regions where stars appear bloated or elongated (high FWHM). A uniform green grid means your optics are well-corrected and evenly focused across the field.

Common patterns you might see:
- Corners redder than center: field curvature or coma from your optical train. Consider a field flattener or coma corrector.
- One side redder: tilt in your imaging train (camera not square to the optical axis). Check your adapters and spacers.
- Everything red: poor focus or poor seeing conditions.
- Uniform green: excellent optics and focus — the ideal result.

The color scale is normalized to the 5th and 95th percentiles of your data, so it automatically adapts to show the variation present in your specific setup.
''';

const _kAstrometricResidualsInfo = '''
Astrometric residuals measure the accuracy of the plate solution — how well the computed sky coordinates match the actual positions of known catalog stars in your image. After plate solving identifies stars and fits a coordinate model, the residual for each star is the angular distance between where the model says it should be and where it actually appears.

The RMS (Root Mean Square) value combines all individual residuals into a single accuracy metric, expressed in arcseconds. Lower RMS means a more accurate astrometric solution.

Typical values:
- Below 0.5": Excellent astrometry, suitable for scientific reporting.
- 0.5" to 1.5": Good astrometry, adequate for most purposes.
- 1.5" to 3.0": Acceptable, but may indicate optical distortion or a sparse star field.
- Above 3.0": Poor fit — may indicate tracking issues, severe distortion at the field edges, or an incorrect focal length in the solver configuration.

The "recommendation" code (when present) provides guidance from the astrometric solver about potential improvements, such as refining the distortion model, adjusting the focal length, or using a denser reference catalog.

High residuals can result from: poor tracking (field rotation or drift), optical distortion not accounted for in the plate model, incorrectly specified pixel scale or focal length, or very few reference stars in the field.
''';

const _kMovingObjectCandidatesInfo = '''
This panel lists the individual moving object candidates detected in your session, ranked by confidence. For each candidate, you can see:

- Name/ID: If the object matches a known asteroid or comet from the MPC (Minor Planet Center) database, its designation is shown. Otherwise, a temporary candidate ID is assigned.

- Confidence: A percentage score indicating how likely this detection is to be a real moving object versus an artifact. Scores above 80% are generally reliable. Lower scores may indicate hot pixels, cosmic rays, or satellite trails that partially mimic asteroid-like motion.

- Motion rate: The apparent angular velocity in arcseconds per minute. Main-belt asteroids typically move at 0.3-1.0"/min, while NEOs (Near-Earth Objects) can move much faster (up to several arcseconds per minute or more). Very fast motion (>10"/min) is usually an artificial satellite.

To confirm a candidate as a real discovery, you would need to image the same field on subsequent nights to verify the object is still present and moving along a consistent orbital arc. Confirmed new discoveries can be reported to the Minor Planet Center for official designation.

The list shows up to 6 candidates. If many low-confidence candidates appear, it may indicate noisy data or a crowded star field rather than actual moving objects.
''';

const _kNarrowbandRatiosInfo = '''
Narrowband emission line ratios compare the relative intensities of specific wavelengths of light emitted by ionized gas in nebulae. These ratios reveal the physical conditions — temperature, density, and ionization state — of the gas you're imaging.

The three ratios shown are:

SII/H-alpha: Compares sulfur-II emission (672nm) to hydrogen-alpha emission (656nm). Elevated SII/Ha ratios indicate shock-heated gas, such as supernova remnants (SNRs) or Herbig-Haro objects. Typical HII regions (star-forming nebulae) have SII/Ha < 0.4, while SNRs often exceed 0.4-0.5.

OIII/H-alpha: Compares doubly-ionized oxygen emission (496/501nm) to hydrogen-alpha. High OIII/Ha ratios indicate highly ionized gas, typically found near hot stars (planetary nebulae, Wolf-Rayet bubbles) or in the outer zones of large HII regions. This ratio is a proxy for the ionization parameter of the gas.

SII/OIII: Compares sulfur-II to oxygen-III directly. This ratio helps distinguish between different excitation mechanisms. Low SII/OIII values suggest photoionization by UV radiation from hot stars, while high values point toward collisional excitation from shocks.

To generate ratios, Skotiq needs at least one frame captured through each of the three narrowband filters (H-alpha, OIII, SII) in the current session. The frames are median-sampled and their integrated fluxes are compared to produce each ratio.

These ratios are widely used in professional astronomy for classifying nebulae, mapping shock fronts, and studying the interstellar medium. They form the basis of BPT (Baldwin-Phillips-Terlevich) diagnostic diagrams used to classify emission-line objects.
''';

const _kPhotometricTransformsInfo = '''
Photometric transformation coefficients convert your instrumental magnitudes into a standard photometric system (such as Johnson-Cousins UBVRI or Sloan ugriz). Without these coefficients, your brightness measurements are only relative — useful for differential photometry, but not directly comparable to catalog values or measurements from other observatories.

The transformation equation is: M_std = m_inst - k*X + T*(B-V) + ZP

Where:
- M_std: Standard magnitude (the calibrated result)
- m_inst: Instrumental magnitude (what your camera measures)
- k: Extinction coefficient (how much the atmosphere dims starlight per unit airmass)
- X: Airmass (how much atmosphere the light passes through; more at lower elevations)
- T: Color term (corrects for your filter+CCD combination's color response vs. the standard system)
- (B-V): Color index of the star (blue minus visual magnitude, a measure of stellar color)
- ZP: Zero point (the offset between your instrumental scale and the standard scale)

To compute these coefficients, Skotiq uses a least-squares fit of catalog star magnitudes against your measured instrumental magnitudes. The calibration wizard guides you through selecting a suitable frame with many catalog stars, matching them, and computing the fit.

The RMS residual indicates how well the transform fits the data. Values below 0.03 mag are excellent; 0.03-0.05 is good; 0.05-0.10 is acceptable for most work. Higher values may indicate color terms that vary across the field, poor focus, or thin clouds.

Once saved, these coefficients are automatically applied to new photometry measurements, converting differential magnitudes into absolute standard magnitudes suitable for AAVSO submission and cross-observatory comparison.
''';

/// Map of card titles to their info content for easy lookup.
const _kScienceInfoContent = <String, String>{
  'Calibration': _kCalibrationInfo,
  'Lim Mag (5-sigma)': _kLimMagInfo,
  'Transparency': _kTransparencyInfo,
  'Moving Objects': _kMovingObjectsInfo,
  'Differential Photometry': _kDifferentialPhotometryInfo,
  'Transparency Trend': _kTransparencyTrendInfo,
  'PSF Field Map': _kPsfFieldMapInfo,
  'Astrometric Residuals': _kAstrometricResidualsInfo,
  'Moving Object Candidates': _kMovingObjectCandidatesInfo,
  'Narrowband Ratios': _kNarrowbandRatiosInfo,
  'Photometric Transforms': _kPhotometricTransformsInfo,
};

class _ScienceInfoButton extends StatelessWidget {
  final String title;

  const _ScienceInfoButton({required this.title});

  @override
  Widget build(BuildContext context) {
    final body = _kScienceInfoContent[title];
    if (body == null) return const SizedBox.shrink();
    return ScienceInfoButton(title: title, body: body);
  }
}

class _ChartPoint {
  final DateTime time;
  final double value;

  const _ChartPoint(this.time, this.value);
}

class _SeriesChartCard extends StatelessWidget {
  final SkotiqColors colors;
  final String title;
  final String yLabel;
  final List<_ChartPoint> points;
  final Color color;
  // Optional inline button that opens the consolidated export hub with the
  // matching dataset pre-selected, so there is one canonical export surface.
  final Widget? hubExportButton;

  const _SeriesChartCard({
    required this.colors,
    required this.title,
    required this.yLabel,
    required this.points,
    required this.color,
    this.hubExportButton,
  });

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return SkotiqCard(
        child: AdaptiveChartContainer.fixed(
          height: 240,
          child: Center(
            child: Text(
              '$title has no data yet',
              style:
                  SkotiqTypography.body.copyWith(color: colors.textMuted),
            ),
          ),
        ),
      );
    }

    final sorted = points.toList(growable: false)
      ..sort((a, b) => a.time.compareTo(b.time));
    final start = sorted.first.time;
    final spots = sorted
        .map(
          (point) => FlSpot(
              point.time.difference(start).inSeconds.toDouble(), point.value),
        )
        .toList(growable: false);

    var minY = sorted.first.value;
    var maxY = sorted.first.value;
    for (final point in sorted) {
      if (point.value < minY) {
        minY = point.value;
      }
      if (point.value > maxY) {
        maxY = point.value;
      }
    }

    // Shared "nice" axis: bounds snapped to tick multiples so fl_chart's
    // boundary labels coincide with ticks instead of printing a second value a
    // few pixels away (this chart showed "101.0" over "100.0" and "75.0" over
    // "74.7" on the transparency trend).
    final axis = NiceAxis.forRange(minY, maxY);
    final maxX = spots.last.x == 0 ? 1.0 : spots.last.x;
    // Exact division puts the last tick on the axis end, so the boundary label
    // is a tick rather than a second copy a few pixels away.
    final xInterval = maxX / 4;

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: SkotiqTypography.bodyStrong
                      .copyWith(color: colors.textPrimary),
                ),
              ),
              if (hubExportButton != null) hubExportButton!,
              _ScienceInfoButton(title: title),
            ],
          ),
          const SizedBox(height: 12),
          AdaptiveChartContainer(
            preferredHeight: 190,
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: maxX,
                minY: axis.min,
                maxY: axis.max,
                borderData: FlBorderData(
                  show: true,
                  border: Border.all(color: colors.border),
                ),
                gridData: FlGridData(
                  drawVerticalLine: true,
                  horizontalInterval: axis.interval,
                  verticalInterval: xInterval,
                  getDrawingHorizontalLine: (_) =>
                      FlLine(color: colors.border.withValues(alpha: 0.35)),
                  getDrawingVerticalLine: (_) =>
                      FlLine(color: colors.border.withValues(alpha: 0.25)),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 24,
                      interval: xInterval,
                      getTitlesWidget: (value, meta) {
                        return Text(
                          elapsedAxisLabel(value),
                          style: SkotiqTypography.caption
                              .copyWith(color: colors.textSecondary),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    axisNameWidget: Text(
                      yLabel,
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.textSecondary),
                    ),
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 44,
                      interval: axis.interval,
                      getTitlesWidget: (value, meta) => Text(
                        axis.label(value),
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.textSecondary),
                      ),
                    ),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    color: color,
                    barWidth: 2,
                    isCurved: false,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      color: color.withValues(alpha: 0.12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
