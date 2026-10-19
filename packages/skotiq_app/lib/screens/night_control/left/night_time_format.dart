// Times and durations as the header and the plan column print them.
//
// Every DateTime the plan view models carry is already on the operator's
// clock, so these read the fields as they are; converting again would shift
// a site in another time zone twice.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../localization/skotiq_localizations.dart';
import '../data/plan/night_plan_inputs.dart';

/// Marks a time or a length the estimator produced rather than one recorded.
const String kNightEstimatePrefix = '≈';

String _two(int v) => v.toString().padLeft(2, '0');

/// `23:52` for a time already on the operator's clock.
String nightHm(DateTime onClock) =>
    '${_two(onClock.hour)}:${_two(onClock.minute)}';

/// `≈03:40` when [estimated], else `03:40`.
String nightHmMaybeEstimated(DateTime onClock, {required bool estimated}) =>
    estimated ? '$kNightEstimatePrefix${nightHm(onClock)}' : nightHm(onClock);

/// `4 h 04 m`, `7 h`, `12 m`. A negative length reads as zero minutes.
String nightSpan(SkotiqLocalizations l10n, Duration d) {
  final minutes = d.isNegative ? 0 : d.inMinutes;
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return l10n.text('nightCtlM', params: {'m': '$m'});
  if (m == 0) return l10n.text('nightCtlH', params: {'h': '$h'});
  return l10n.text('nightCtlHm', params: {'h': '$h', 'm': _two(m)});
}

/// `3h00`, `0h36`: the Plan rows' captured time.
String nightFilterTime(Duration d) {
  final minutes = d.isNegative ? 0 : d.inMinutes;
  return '${minutes ~/ 60}h${_two(minutes % 60)}';
}

/// Now on the operator's clock, on Tonight's shared 30 s tick.
DateTime nightNowOnClock(WidgetRef ref) =>
    ref.watch(clockProvider).toNightClock(ref.watch(nightNowProvider));
