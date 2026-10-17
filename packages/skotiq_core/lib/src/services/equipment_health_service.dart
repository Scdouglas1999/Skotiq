import '../database/database.dart' show ImagingSession;
import 'usb_disconnect_log.dart';

class DeviceHealthSnapshot {
  final String deviceId;
  final int lastSuccessfulTimestampMs;
  final bool isHealthy;

  /// Number of times this device disconnected (or surfaced a connection
  /// error) in the past 24 hours. Used by the pre-flight USB-stability
  /// check (`UsbStabilityRule`) — > 3 disconnects warns the user that the
  /// cable / hub / driver is suspect before a long unattended run begins.
  ///
  /// Defaults to 0; an unhealthy device with no count still surfaces as
  /// "device heartbeat failure" through `analyze()`.
  final int disconnectCountLast24h;

  /// Optional human-readable device label (for UI / error messages).
  /// Falls back to [deviceId] when null.
  final String? deviceLabel;

  const DeviceHealthSnapshot({
    required this.deviceId,
    required this.lastSuccessfulTimestampMs,
    required this.isHealthy,
    this.disconnectCountLast24h = 0,
    this.deviceLabel,
  });

  String get displayName => deviceLabel ?? deviceId;
}

enum EquipmentHealthSeverity { info, warning, critical }

class EquipmentHealthInsight {
  final String title;
  final String message;
  final EquipmentHealthSeverity severity;

  const EquipmentHealthInsight({
    required this.title,
    required this.message,
    required this.severity,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EquipmentHealthInsight &&
          other.title == title &&
          other.message == message &&
          other.severity == severity;

  @override
  int get hashCode => Object.hash(title, message, severity);
}

class EquipmentHealthReport {
  final double score;
  final List<EquipmentHealthInsight> insights;

  /// Whether [score] is backed by any evidence.
  ///
  /// The score is a DEGRADATION score: it starts at 100 and subtracts for
  /// guiding/HFR drift, failed exposures, and unhealthy heartbeats. With no
  /// session history and no connected devices there is nothing to subtract,
  /// so a rig with no history would otherwise score a perfect 100. When this
  /// is false the UI must present the score as un-assessed: no evidence is not
  /// evidence of health.
  final bool assessed;

  const EquipmentHealthReport({
    required this.score,
    required this.insights,
    this.assessed = true,
  });

  /// Value equality so `equipmentHealthReportProvider` does not notify (and the
  /// equipment screen's status rail does not rebuild) every time an unrelated
  /// device-state tick recomputes an identical report. Without this every
  /// recompute produced a new object identity and Riverpod treated it as a
  /// change.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! EquipmentHealthReport) return false;
    if (other.score != score || other.assessed != assessed) return false;
    if (other.insights.length != insights.length) return false;
    for (var i = 0; i < insights.length; i++) {
      if (other.insights[i] != insights[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(score, assessed, Object.hashAll(insights));
}

/// Connected-device descriptor used by [EquipmentHealthService.buildSnapshots]
/// to merge a USB disconnect log + the live connection state into one
/// `DeviceHealthSnapshot` list. Matches the data the
/// `*StateProvider` notifiers already track (deviceId, displayName,
/// lastSuccessfulCommunication, isHealthy) without depending on any
/// particular notifier so a remote backend or a headless tool can build
/// the same shape.
class DeviceConnectionDescriptor {
  final String deviceId;
  final String? deviceLabel;
  final bool isHealthy;
  final DateTime? lastSuccessfulCommunication;

  const DeviceConnectionDescriptor({
    required this.deviceId,
    this.deviceLabel,
    this.isHealthy = true,
    this.lastSuccessfulCommunication,
  });
}

/// Longitudinal equipment health scoring from session trends and heartbeats.
class EquipmentHealthService {
  const EquipmentHealthService();

  /// Build [DeviceHealthSnapshot]s from the connected-device list plus
  /// the rolling USB disconnect log.
  ///
  /// This is the production path that fills
  /// [DeviceHealthSnapshot.disconnectCountLast24h]. The pre-flight USB
  /// stability rule reads the resulting list via
  /// `deviceHealthSnapshotsProvider`; the post-session diagnostics
  /// summary derives a "disconnects during session" count from the same
  /// log directly.
  ///
  /// Devices that appear in the disconnect log but not in [connected]
  /// are included (with `isHealthy: false`) so the user still sees the
  /// flake count for a device that hasn't reconnected — e.g. an INDI
  /// camera that vanished mid-session.
  List<DeviceHealthSnapshot> buildSnapshots({
    required List<DeviceConnectionDescriptor> connected,
    required UsbDisconnectLog disconnectLog,
    DateTime? now,
  }) {
    final perDeviceCounts = disconnectLog.perDeviceCounts(now: now);
    final byId = <String, DeviceHealthSnapshot>{};

    for (final device in connected) {
      final id = device.deviceId;
      byId[id] = DeviceHealthSnapshot(
        deviceId: id,
        deviceLabel: device.deviceLabel,
        lastSuccessfulTimestampMs:
            device.lastSuccessfulCommunication?.millisecondsSinceEpoch ?? 0,
        isHealthy: device.isHealthy,
        disconnectCountLast24h: perDeviceCounts[id] ?? 0,
      );
    }

    // Pull in devices that disconnected and never came back (or that
    // reconnected through a path that didn't populate the connected
    // list). Without this branch the snapshot list would silently drop
    // the most interesting cases — a USB cable yanked at the start of
    // a run that the user is unaware of.
    for (final entry in perDeviceCounts.entries) {
      if (byId.containsKey(entry.key)) continue;
      byId[entry.key] = DeviceHealthSnapshot(
        deviceId: entry.key,
        lastSuccessfulTimestampMs: 0,
        isHealthy: false,
        disconnectCountLast24h: entry.value,
      );
    }

    return byId.values.toList(growable: false);
  }

  /// Points deducted when a device the active profile assigns is not connected.
  ///
  /// Sized so a single offline profile device cannot leave the score in the
  /// "Excellent" band (>= 85). The observed failure this guards: a profile whose
  /// guider never connected on launch still scored `100 - Excellent` in green
  /// because the degradation score only subtracted for guiding/HFR drift, failed
  /// exposures, and unhealthy HEARTBEATS — and a device that never connected has
  /// no heartbeat, so it deducted nothing.
  static const double offlineProfileDevicePenalty = 20.0;

  EquipmentHealthReport analyze({
    required List<ImagingSession> sessions,
    required List<DeviceHealthSnapshot> deviceHealth,
    List<String> offlineProfileDevices = const <String>[],
  }) {
    final recentSessions = [...sessions]
      ..sort((a, b) => b.startTime.compareTo(a.startTime));

    final latest = recentSessions.take(5).toList(growable: false);
    final baseline = recentSessions.skip(5).take(10).toList(growable: false);

    final recentGuiding = _mean(
      latest.map((session) => session.avgGuidingRms).whereType<double>(),
    );
    // Null when there is no history to compare against, NOT a stand-in number.
    //
    // `baseline` is sessions 6..15, so it is empty for every user with five or
    // fewer sessions. A clamped mean of nothing would be a floor value no rig
    // ever produced, and every degradation trigger would fire against it on a
    // user's first night.
    final baselineGuiding = _meanOrNull(
      baseline.map((session) => session.avgGuidingRms).whereType<double>(),
    );
    final recentHfr = _mean(
      latest.map((session) => session.avgHfr).whereType<double>(),
    );
    final baselineHfr = _meanOrNull(
      baseline.map((session) => session.avgHfr).whereType<double>(),
    );
    final failureRate = _failureRate(latest);
    final unhealthyDevices = deviceHealth
        .where((snapshot) => !snapshot.isHealthy)
        .toList(growable: false);

    var score = 100.0;
    final insights = <EquipmentHealthInsight>[];

    if (baselineGuiding != null &&
        recentGuiding > 0 &&
        recentGuiding > baselineGuiding * 1.25) {
      score -= 18;
      insights.add(
        EquipmentHealthInsight(
          title: 'Guiding degradation',
          message:
              'Recent guiding RMS is ${(recentGuiding / baselineGuiding).toStringAsFixed(2)}x the historical baseline. Check balance, flexure, and backlash.',
          severity: EquipmentHealthSeverity.warning,
        ),
      );
    }

    if (baselineHfr != null &&
        recentHfr > 0 &&
        recentHfr > baselineHfr * 1.15) {
      score -= 14;
      insights.add(
        const EquipmentHealthInsight(
          title: 'Focus quality drift',
          message:
              'Recent median HFR is elevated versus the longer-term baseline. Inspect focus repeatability and thermal drift compensation.',
          severity: EquipmentHealthSeverity.warning,
        ),
      );
    }

    if (failureRate >= 0.12) {
      score -= 20;
      insights.add(
        EquipmentHealthInsight(
          title: 'Capture reliability risk',
          message:
              'Recent failed-exposure rate is ${(failureRate * 100).toStringAsFixed(0)}%. Review cables, power stability, and camera timeouts.',
          severity: failureRate >= 0.2
              ? EquipmentHealthSeverity.critical
              : EquipmentHealthSeverity.warning,
        ),
      );
    }

    if (unhealthyDevices.isNotEmpty) {
      score -= 25;
      insights.add(
        EquipmentHealthInsight(
          title: 'Device heartbeat failures',
          message:
              'Unhealthy devices detected: ${unhealthyDevices.map((snapshot) => snapshot.displayName).join(', ')}.',
          severity: EquipmentHealthSeverity.critical,
        ),
      );
    }

    if (offlineProfileDevices.isNotEmpty) {
      score -= offlineProfileDevicePenalty;
      final names = offlineProfileDevices.join(', ');
      insights.add(
        EquipmentHealthInsight(
          title: offlineProfileDevices.length == 1
              ? 'Profile device not connected'
              : 'Profile devices not connected',
          message:
              'Your equipment profile assigns $names but '
              '${offlineProfileDevices.length == 1 ? 'it is' : 'they are'} not '
              'connected. Reconnect before an unattended run — the rig cannot '
              'use hardware it never reached.',
          severity: EquipmentHealthSeverity.critical,
        ),
      );
    }

    // No history AND no devices to watch means nothing could have been
    // measured — say so instead of implying a clean bill of health.
    final assessed =
        recentSessions.isNotEmpty ||
        deviceHealth.isNotEmpty ||
        offlineProfileDevices.isNotEmpty;

    if (insights.isEmpty) {
      insights.add(
        assessed
            ? const EquipmentHealthInsight(
                title: 'Equipment health stable',
                message:
                    'No negative trend exceeded alert thresholds in the recent session history.',
                severity: EquipmentHealthSeverity.info,
              )
            : const EquipmentHealthInsight(
                title: 'Not enough data yet',
                message:
                    'No completed sessions and no connected devices to measure, so '
                    'equipment health has not been assessed. It appears after your '
                    'first session.',
                severity: EquipmentHealthSeverity.info,
              ),
      );
    }

    return EquipmentHealthReport(
      score: score.clamp(0.0, 100.0),
      insights: insights,
      assessed: assessed,
    );
  }

  /// Mean of [values], or null when there is nothing to average.
  ///
  /// Distinct from [_mean], which returns 0.0 for an empty input. That zero was
  /// being clamped into a plausible-looking baseline and compared against, so
  /// "no history" was indistinguishable from "excellent history".
  double? _meanOrNull(Iterable<double> values) {
    final list = values.toList(growable: false);
    return list.isEmpty ? null : _mean(list);
  }

  double _mean(Iterable<double> values) {
    final list = values
        .where((value) => value.isFinite)
        .toList(growable: false);
    if (list.isEmpty) {
      return 0.0;
    }
    return list.reduce((a, b) => a + b) / list.length;
  }

  double _failureRate(List<ImagingSession> sessions) {
    if (sessions.isEmpty) {
      return 0.0;
    }
    final failed = sessions.fold<int>(
      0,
      (sum, session) => sum + session.failedExposures,
    );
    final total = sessions.fold<int>(
      0,
      (sum, session) => sum + session.totalExposures,
    );
    if (total <= 0) {
      return 0.0;
    }
    return failed / total;
  }
}
