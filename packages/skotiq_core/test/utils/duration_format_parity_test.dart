// Parity pins for the `format-duration` consolidation.
//
// Every `_ref*` function below is a VERBATIM copy of one of the private
// `_formatDuration` helpers `DurationFormat` retired. The sweeps assert the
// canonical reproduces them byte-for-byte, and each documented exception is
// pinned on its own so a divergence cannot be introduced silently.
//
// The one intended difference: minute-only copies render "0m" for a sub-minute
// duration. All four styles render seconds below a minute, so "0m" is
// unreachable.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

// --- retired copies, verbatim -----------------------------------------------

/// `sequence_progress_bar.dart`, `capture_panel.dart` (hours/minutes floor).
String _refHmsFloorDouble(double seconds) {
  final hours = (seconds / 3600).floor();
  final minutes = ((seconds % 3600) / 60).floor();
  final secs = (seconds % 60).floor();
  if (hours > 0) return '${hours}h ${minutes}m ${secs}s';
  if (minutes > 0) return '${minutes}m ${secs}s';
  return '${secs}s';
}

/// `notes_service.dart`, `notification_service.dart`,
/// `session_report_service.dart` (×2).
String _refHmsDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '${h}h ${m}m ${s}s';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}

/// `session_picker_screen.dart`, `session_replay_screen.dart`,
/// `session_progress_card.dart`, `history_tab.dart`, `header_overview.dart`.
String _refHoursMinutesDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '${h}h ${m}m';
  if (m > 0) return '${m}m ${s}s';
  return '${s}s';
}

/// `widgets/sequence_progress_card.dart` — seconds rounded into a `Duration`.
String _refHoursMinutesRoundedDouble(double seconds) {
  final duration = Duration(seconds: seconds.round());
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final secs = duration.inSeconds.remainder(60);
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m ${secs}s';
  return '${secs}s';
}

/// `session_report_dialog/target_conditions.dart` — milliseconds, then
/// truncated to whole seconds by `Duration`.
String _refHoursMinutesTruncatedDouble(double seconds) {
  final d = Duration(milliseconds: (seconds * 1000).round());
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
  return '${d.inSeconds}s';
}

/// `node_timing_section.dart` — `formatDurationNice`.
String _refHoursMinutesTrimmedDuration(Duration duration) {
  if (duration.inSeconds < 60) {
    return '${duration.inSeconds}s';
  }
  if (duration.inMinutes < 60) {
    final mins = duration.inMinutes;
    final secs = duration.inSeconds % 60;
    if (secs == 0) return '${mins}m';
    return '${mins}m ${secs}s';
  }
  final hours = duration.inHours;
  final mins = duration.inMinutes % 60;
  if (mins == 0) return '${hours}h';
  return '${hours}h ${mins}m';
}

/// `preflight_validation_dialog.dart`, `preflight_validation_dialog/
/// simulation_widgets.dart`, `session_optimizer_service.dart`,
/// `smart_night_dialog.dart` (minus its missing seconds arm).
String _refCompactDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m';
  return '${duration.inSeconds}s';
}

/// `mobile_playback_bar.dart`, `sequence_toolbar/actions_and_estimate.dart`,
/// `sequence_timeline/full_timeline.dart`, `sequence_library_tab/
/// sequence_card.dart`, `quick_start_wizard_dialog.dart` (floor variants).
String _refCompactFloorDouble(double seconds) {
  final hours = (seconds / 3600).floor();
  final minutes = ((seconds % 3600) / 60).floor();
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${minutes}m';
}

/// `target_header_card.dart` — total rounded first, then floored components.
String _refCompactRoundedTotalDouble(double totalSeconds) {
  final seconds = totalSeconds.round();
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${minutes}m';
}

/// `run_dashboard/target_header_panel.dart`, `target_node_properties/
/// budget_preview.dart` — trimmed hours, minutes rounded.
String _refCompactTrimmedRoundedMinutes(double secs) {
  if (secs <= 0) return '0m';
  final h = secs ~/ 3600;
  final m = ((secs % 3600) / 60).round();
  if (h > 0 && m > 0) return '${h}h ${m}m';
  if (h > 0) return '${h}h';
  return '${m}m';
}

/// `observation_report_service.dart` — hours/minutes, no seconds arm at all.
String _refHoursMinutesNoSecondsDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${minutes}m';
}

/// Every whole second across three hours, plus a day-plus tail.
Iterable<int> get _sweep sync* {
  for (var s = 0; s <= 10900; s++) {
    yield s;
  }
  for (final s in const [86399, 86400, 90061, 359999]) {
    yield s;
  }
}

void main() {
  group('hms — units dropped from the left only', () {
    test('reproduces the Duration copies exactly, over a full sweep', () {
      for (final s in _sweep) {
        final d = Duration(seconds: s);
        expect(
          DurationFormat.of(d, style: DurationStyle.hms),
          _refHmsDuration(d),
          reason: '$s s',
        );
      }
    });

    test('reproduces the floor-based double copy on whole seconds', () {
      for (final s in _sweep) {
        expect(
          DurationFormat.seconds(
            s.toDouble(),
            style: DurationStyle.hms,
            rounding: DurationRounding.truncate,
          ),
          _refHmsFloorDouble(s.toDouble()),
          reason: '$s s',
        );
      }
    });

    test('truncating rounding keeps the floor copy exact on fractions', () {
      for (final v in const [0.4, 59.6, 59.999, 3599.9, 3600.5, 7261.75]) {
        expect(
          DurationFormat.seconds(
            v,
            style: DurationStyle.hms,
            rounding: DurationRounding.truncate,
          ),
          _refHmsFloorDouble(v),
          reason: '$v s',
        );
      }
    });

    test('formatIntegrationSeconds is unchanged', () {
      expect(formatIntegrationSeconds(0), '0s');
      expect(formatIntegrationSeconds(-5), '0s');
      expect(formatIntegrationSeconds(double.nan), '0s');
      expect(formatIntegrationSeconds(double.infinity), '0s');
      expect(formatIntegrationSeconds(12), '12s');
      expect(formatIntegrationSeconds(59.6), '1m 0s');
      expect(formatIntegrationSeconds(90), '1m 30s');
      expect(formatIntegrationSeconds(3723), '1h 2m 3s');
      expect(formatIntegrationHours(2.5), '2h 30m 0s');
      expect(formatIntegrationHours(30 / 3600), '30s');
    });

    test('over a day keeps counting hours rather than wrapping', () {
      expect(DurationFormat.seconds(90061), '25h 1m 1s');
      expect(
        DurationFormat.of(const Duration(days: 2, minutes: 3)),
        '48h 3m 0s',
      );
    });
  });

  group('hoursMinutes — hours suppress the seconds field', () {
    test('reproduces the Duration copies exactly, over a full sweep', () {
      for (final s in _sweep) {
        final d = Duration(seconds: s);
        expect(
          DurationFormat.of(d, style: DurationStyle.hoursMinutes),
          _refHoursMinutesDuration(d),
          reason: '$s s',
        );
      }
    });

    test('reproduces the rounded-double copy, whole and fractional', () {
      for (final s in _sweep) {
        expect(
          DurationFormat.seconds(
            s.toDouble(),
            style: DurationStyle.hoursMinutes,
          ),
          _refHoursMinutesRoundedDouble(s.toDouble()),
          reason: '$s s',
        );
      }
      for (final v in const [0.4, 0.6, 59.4, 59.6, 3599.5, 7260.25]) {
        expect(
          DurationFormat.seconds(v, style: DurationStyle.hoursMinutes),
          _refHoursMinutesRoundedDouble(v),
          reason: '$v s',
        );
      }
    });

    test(
      'hoursMinutesTrimmed reproduces formatDurationNice over a full sweep',
      () {
        for (final s in _sweep) {
          final d = Duration(seconds: s);
          expect(
            DurationFormat.of(d, style: DurationStyle.hoursMinutesTrimmed),
            _refHoursMinutesTrimmedDuration(d),
            reason: '$s s',
          );
        }
      },
    );

    test('hoursMinutesTrimmed drops only the zero trailing field', () {
      expect(
        DurationFormat.seconds(3600, style: DurationStyle.hoursMinutesTrimmed),
        '1h',
      );
      expect(
        DurationFormat.seconds(3660, style: DurationStyle.hoursMinutesTrimmed),
        '1h 1m',
      );
      expect(
        DurationFormat.seconds(3661, style: DurationStyle.hoursMinutesTrimmed),
        '1h 1m',
      );
      expect(
        DurationFormat.seconds(300, style: DurationStyle.hoursMinutesTrimmed),
        '5m',
      );
      expect(
        DurationFormat.seconds(330, style: DurationStyle.hoursMinutesTrimmed),
        '5m 30s',
      );
      // hoursMinutes keeps the zero field its callers relied on.
      expect(
        DurationFormat.seconds(3600, style: DurationStyle.hoursMinutes),
        '1h 0m',
      );
      expect(
        DurationFormat.seconds(300, style: DurationStyle.hoursMinutes),
        '5m 0s',
      );
    });

    test('reproduces the millisecond-truncating copy on fractions', () {
      for (final v in const [0.4, 12.2, 59.6, 90.9, 3599.9, 7261.75]) {
        expect(
          DurationFormat.seconds(
            v,
            style: DurationStyle.hoursMinutes,
            rounding: DurationRounding.truncate,
          ),
          _refHoursMinutesTruncatedDouble(v),
          reason: '$v s',
        );
      }
    });
  });

  group('compact — two largest units', () {
    test('reproduces the Duration copies exactly, over a full sweep', () {
      for (final s in _sweep) {
        final d = Duration(seconds: s);
        expect(
          DurationFormat.of(d, style: DurationStyle.compact),
          _refCompactDuration(d),
          reason: '$s s',
        );
      }
    });

    test('reproduces the floor-based double copies at or above a minute', () {
      for (final s in _sweep) {
        if (s < 60) continue; // sub-minute region, pinned separately
        expect(
          DurationFormat.seconds(
            s.toDouble(),
            style: DurationStyle.compact,
            rounding: DurationRounding.truncate,
          ),
          _refCompactFloorDouble(s.toDouble()),
          reason: '$s s',
        );
      }
    });

    test('reproduces the rounded-total copy at or above a minute', () {
      for (final s in _sweep) {
        if (s < 60) continue;
        expect(
          DurationFormat.seconds(s.toDouble(), style: DurationStyle.compact),
          _refCompactRoundedTotalDouble(s.toDouble()),
          reason: '$s s',
        );
      }
    });

    test(
      'reproduces the no-seconds-arm Duration copy at or above a minute',
      () {
        for (final s in _sweep) {
          if (s < 60) continue;
          final d = Duration(seconds: s);
          expect(
            DurationFormat.of(d, style: DurationStyle.compact),
            _refHoursMinutesNoSecondsDuration(d),
            reason: '$s s',
          );
        }
      },
    );
  });

  group('compactTrimmed — a zero minutes field is dropped', () {
    test('keeps the bare hour and the hour+minute shapes', () {
      expect(
        DurationFormat.seconds(3600, style: DurationStyle.compactTrimmed),
        '1h',
      );
      expect(
        DurationFormat.seconds(5400, style: DurationStyle.compactTrimmed),
        '1h 30m',
      );
      expect(
        DurationFormat.seconds(1200, style: DurationStyle.compactTrimmed),
        '20m',
      );
    });

    test('reproduces the minute-rounding copies at or above a minute, except '
        'where their minutes field rounded to 60', () {
      var carries = 0;
      for (final s in _sweep) {
        if (s < 60) continue;
        final v = s.toDouble();
        final old = _refCompactTrimmedRoundedMinutes(v);
        final now = DurationFormat.seconds(
          v,
          style: DurationStyle.compactTrimmed,
          roundToMinute: true,
        );
        if (old.contains('60m') || old == '60m') {
          carries++;
          expect(now, isNot(old), reason: '$s s should have carried');
          continue;
        }
        expect(now, old, reason: '$s s');
      }
      expect(carries, greaterThan(0));
    });

    test('the 60th minute carries into hours instead of printing "1h 60m"', () {
      // Retired copy: 3599 -> "60m", 7195 -> "1h 60m".
      expect(_refCompactTrimmedRoundedMinutes(3599), '60m');
      expect(_refCompactTrimmedRoundedMinutes(7195), '1h 60m');
      expect(
        DurationFormat.seconds(
          3599,
          style: DurationStyle.compactTrimmed,
          roundToMinute: true,
        ),
        '1h',
      );
      expect(
        DurationFormat.seconds(
          7195,
          style: DurationStyle.compactTrimmed,
          roundToMinute: true,
        ),
        '2h',
      );
    });

    test('roundToMinute rounds the leftover seconds into the minutes', () {
      // 3690 s: the retired copy read round(90/60) = 2 minutes.
      expect(_refCompactTrimmedRoundedMinutes(3690), '1h 2m');
      expect(
        DurationFormat.seconds(
          3690,
          style: DurationStyle.compactTrimmed,
          roundToMinute: true,
        ),
        '1h 2m',
      );
      expect(
        DurationFormat.seconds(
          100,
          style: DurationStyle.compact,
          roundToMinute: true,
        ),
        '2m',
      );
      expect(DurationFormat.seconds(100, style: DurationStyle.compact), '1m');
    });
  });

  group('the "0m" class is unreachable', () {
    test('every style renders seconds below one minute', () {
      for (final style in DurationStyle.values) {
        for (final s in const [1, 12, 20, 30, 45, 59]) {
          expect(
            DurationFormat.seconds(s, style: style),
            '${s}s',
            reason: '$style / $s s',
          );
          expect(
            DurationFormat.of(Duration(seconds: s), style: style),
            '${s}s',
            reason: '$style / $s s',
          );
        }
      }
    });

    test('roundToMinute does not resurrect it', () {
      for (final style in const [
        DurationStyle.compact,
        DurationStyle.compactTrimmed,
      ]) {
        for (final s in const [1, 20, 30, 59]) {
          expect(
            DurationFormat.seconds(s, style: style, roundToMinute: true),
            '${s}s',
          );
        }
      }
    });

    test('what the retired minute-only copies printed instead', () {
      expect(_refCompactFloorDouble(20), '0m');
      expect(_refCompactRoundedTotalDouble(20), '0m');
      expect(_refCompactTrimmedRoundedMinutes(20), '0m');
      // 4 x 3 s — a 12-second run.
      expect(_refCompactRoundedTotalDouble(12), '0m');
      expect(DurationFormat.seconds(12, style: DurationStyle.compact), '12s');
    });
  });

  group('degenerate inputs', () {
    test('zero, negative and non-finite collapse to 0s in every style', () {
      for (final style in DurationStyle.values) {
        for (final v in const [
          0.0,
          -0.0,
          -1.0,
          -3600.0,
          double.nan,
          double.infinity,
          double.negativeInfinity,
        ]) {
          expect(
            DurationFormat.seconds(v, style: style),
            '0s',
            reason: '$style / $v',
          );
        }
        expect(DurationFormat.of(Duration.zero, style: style), '0s');
        expect(
          DurationFormat.of(const Duration(minutes: -5), style: style),
          '0s',
        );
      }
    });

    test('sub-second positives round or truncate as asked', () {
      expect(DurationFormat.seconds(0.6), '1s');
      expect(
        DurationFormat.seconds(0.6, rounding: DurationRounding.truncate),
        '0s',
      );
      expect(DurationFormat.seconds(0.4), '0s');
    });
  });
}
