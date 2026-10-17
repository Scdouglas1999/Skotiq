part of '../object_details_panel.dart';

extension _ObjectDetailsPanelVisibilitySections on ObjectDetailsPanel {
  Widget _buildVisibilitySection(
    double altitude,
    double azimuth,
    Color txtColor,
    Color accent,
  ) {
    final isVisible = altitude > 0;
    final statusColor = isVisible ? Colors.green : Colors.red;
    final statusText = isVisible ? 'Above Horizon' : 'Below Horizon';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Current Visibility',
              style: TextStyle(
                color: txtColor.withValues(alpha: 0.7),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                statusText,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildInfoRow('Altitude', '${altitude.toStringAsFixed(1)}°', txtColor),
        _buildInfoRow('Azimuth', '${azimuth.toStringAsFixed(1)}°', txtColor),
      ],
    );
  }

  Widget _buildVisibilityGraph(WidgetRef ref, Color txtColor, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Altitude Over 24 Hours',
          style: TextStyle(
            color: txtColor.withValues(alpha: 0.7),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 100,
          decoration: BoxDecoration(
            color: txtColor.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: CustomPaint(
            size: const Size(double.infinity, 100),
            painter: _AltitudeGraphPainter(
              object: object,
              ref: ref,
              lineColor: accent,
              gridColor: txtColor.withValues(alpha: 0.2),
              cloudCoverPercent: cloudCoverPercent,
              // Watch (not read): if the user changes their effective
              // horizon mid-session the painter must rebuild — passing
              // the value as a constructor field combined with
              // shouldRepaint comparing it gives Flutter the trigger.
              effectiveHorizonDeg: ref.watch(
                planetariumEffectiveHorizonDegProvider,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAirmassChart(WidgetRef ref, Color txtColor, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Airmass Over 24 Hours',
              style: TextStyle(
                color: txtColor.withValues(alpha: 0.7),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            // Legend
            _buildAirmassLegendDot(const Color(0xFF4CAF50), '< 1.5', txtColor),
            const SizedBox(width: 6),
            _buildAirmassLegendDot(const Color(0xFFFFC107), '1.5-2', txtColor),
            const SizedBox(width: 6),
            _buildAirmassLegendDot(const Color(0xFFF44336), '> 2.0', txtColor),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 120,
          decoration: BoxDecoration(
            color: txtColor.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: CustomPaint(
            size: const Size(double.infinity, 120),
            painter: _AirmassChartPainter(
              object: object,
              ref: ref,
              txtColor: txtColor,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAirmassLegendDot(Color color, String label, Color txtColor) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 3),
        Text(
          label,
          style: TextStyle(fontSize: 9, color: txtColor.withValues(alpha: 0.5)),
        ),
      ],
    );
  }

  Widget _buildRiseTransitSetSection(
    WidgetRef ref,
    ({double latitude, double longitude}) site,
    Color txtColor,
  ) {
    final obsTime = ref.watch(observationMinuteProvider);
    // Rise/set computed against the user's effective
    // horizon (e.g. 20° to clear trees), not the mathematical 0°. The same
    // value drives the Run Dashboard time-to-set stat so the two surfaces
    // agree to the second.
    final horizonDeg = ref.watch(planetariumEffectiveHorizonDegProvider);
    final visibility = ref.watch(
      objectVisibilityProvider((
        raDeg: object.coordinates.ra * 15,
        decDeg: object.coordinates.dec,
        // The NIGHT containing the observation time. The scan runs local noon
        // to noon, so handing it the raw instant described the FOLLOWING night
        // from midnight until noon — the panel would report a rise/transit/set
        // a whole sidereal day away from the one the user is observing.
        nightDate: AstronomyCalculations.nightDateOf(obsTime),
        latitudeDeg: site.latitude,
        longitudeDeg: site.longitude,
        minAltitude: horizonDeg,
      )),
    );

    var riseText = _formatTime(visibility.riseTime);
    var transitText = _formatTime(visibility.transitTime);
    var setText = _formatTime(visibility.setTime);

    if (visibility.neverRises) {
      riseText = 'Never';
      setText = 'Never';
    } else if (visibility.isCircumpolar) {
      riseText = 'Always';
      setText = 'Always';
    }

    // Label hint: when the user has set a non-zero horizon, surface it so
    // the displayed times aren't mistaken for the mathematical horizon.
    final headerLabel = horizonDeg > 0
        ? 'Rise / Transit / Set (≥${horizonDeg.toStringAsFixed(0)}°)'
        : 'Rise / Transit / Set';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          headerLabel,
          style: TextStyle(
            color: txtColor.withValues(alpha: 0.7),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildTimeColumn(LucideIcons.sunrise, 'Rise', riseText, txtColor),
            _buildTimeColumn(
              LucideIcons.arrowUp,
              'Transit',
              transitText,
              txtColor,
            ),
            _buildTimeColumn(LucideIcons.sunset, 'Set', setText, txtColor),
          ],
        ),
      ],
    );
  }

  /// Stands in for every section this panel measures from the observer's
  /// horizon while no observing site is on record.
  Widget _buildNoSiteNote(Color txtColor) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: txtColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            LucideIcons.mapPin,
            size: 14,
            color: txtColor.withValues(alpha: 0.6),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Set an observing site to see altitude, rise and set times.',
              style: TextStyle(
                color: txtColor.withValues(alpha: 0.7),
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '--:--';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildTimeColumn(
    IconData icon,
    String label,
    String time,
    Color txtColor,
  ) {
    return Column(
      children: [
        Icon(icon, size: 16, color: txtColor.withValues(alpha: 0.7)),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: txtColor.withValues(alpha: 0.5),
            fontSize: 10,
          ),
        ),
        Text(
          time,
          style: TextStyle(
            color: txtColor,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  // Quick stats bar

  /// Build a quick stats bar showing altitude, transit time, and moon distance
  Widget _buildQuickStats(
    WidgetRef ref,
    ({double latitude, double longitude}) site,
    double altitude,
    Color txtColor,
  ) {
    final obsTime = ref.watch(observationMinuteProvider);

    // Calculate transit time
    final visibility = ref.watch(
      objectVisibilityProvider((
        raDeg: object.coordinates.ra * 15,
        decDeg: object.coordinates.dec,
        // Same night anchor as the Rise/Transit/Set section above, so the quick
        // stats bar cannot quote a different night's transit than the panel it
        // sits in.
        nightDate: AstronomyCalculations.nightDateOf(obsTime),
        latitudeDeg: site.latitude,
        longitudeDeg: site.longitude,
        minAltitude: 0,
      )),
    );

    // Format transit time
    String transitTime = '--:--';
    if (visibility.transitTime != null) {
      final t = visibility.transitTime!;
      transitTime =
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    }

    // Calculate moon distance (angular separation from moon)
    final (moonRa, moonDec, _) = AstronomyCalculations.moonPosition(obsTime);
    final moonDist = AstronomyCalculations.angularSeparation(
      ra1Deg: object.coordinates.ra * 15,
      dec1Deg: object.coordinates.dec,
      ra2Deg: moonRa,
      dec2Deg: moonDec,
    );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: txtColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _StatItem(
            icon: LucideIcons.mountain,
            label: 'Alt',
            value: '${altitude.toStringAsFixed(0)}°',
            color: txtColor,
          ),
          _StatItem(
            icon: LucideIcons.clock,
            label: 'Transit',
            value: transitTime,
            color: txtColor,
          ),
          _StatItem(
            icon: LucideIcons.moon,
            label: 'Moon',
            value: '${moonDist.toStringAsFixed(0)}°',
            color: txtColor,
          ),
        ],
      ),
    );
  }

  // Visibility score indicator

  /// Calculate visibility score (0-100) based on altitude, moon phase, and twilight
  int _calculateVisibilityScore(
    WidgetRef ref,
    ({double latitude, double longitude}) site,
    double altitude,
  ) {
    final obsTime = ref.watch(observationMinuteProvider);

    // Start with base score of 0
    var score = 0.0;

    // Altitude score (0-40 points)
    // Objects below horizon get 0, objects at zenith get 40
    if (altitude > 0) {
      score += (altitude / 90) * 40;
    }

    // Moon phase score (0-30 points)
    // New moon = 30 points, Full moon = 0 points
    final moonIllumination = AstronomyCalculations.moonIllumination(obsTime);
    score += ((100 - moonIllumination) / 100) * 30;

    // Moon distance score (0-15 points)
    // Far from moon = 15 points, close to moon = 0 points
    final (moonRa, moonDec, _) = AstronomyCalculations.moonPosition(obsTime);
    final moonDist = AstronomyCalculations.angularSeparation(
      ra1Deg: object.coordinates.ra * 15,
      dec1Deg: object.coordinates.dec,
      ra2Deg: moonRa,
      dec2Deg: moonDec,
    );
    score += math.min(moonDist / 60, 1.0) * 15; // Max at 60 degrees

    // Twilight/darkness score (0-15 points)
    // Full darkness (sun < -18°) = 15 points
    final sunAlt = AstronomyCalculations.sunAltitude(
      dt: obsTime,
      latitudeDeg: site.latitude,
      longitudeDeg: site.longitude,
    );
    if (sunAlt < -18) {
      score += 15; // Astronomical darkness
    } else if (sunAlt < -12) {
      score += 10; // Nautical twilight
    } else if (sunAlt < -6) {
      score += 5; // Civil twilight
    } else if (sunAlt < 0) {
      score += 2; // Just below horizon
    }
    // Daytime = 0 points

    return score.round().clamp(0, 100);
  }

  /// Build visibility score indicator widget
  Widget _buildVisibilityIndicator(int score) {
    final color = score >= 70
        ? Colors.green
        : score >= 40
        ? Colors.amber
        : Colors.red;
    final label = score >= 70
        ? 'Excellent'
        : score >= 40
        ? 'Fair'
        : 'Poor';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.eye, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            '$score - $label',
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
