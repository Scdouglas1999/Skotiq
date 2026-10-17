import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/logging_service.dart';
import '../utils/aligned_ticker.dart';
import 'settings_provider.dart';

/// Time-source abstraction for Skotiq.
///
/// Why: a remote observatory operator may live in one time zone while the
/// rig sits in another. The Settings → Location → Timezone dropdown and
/// "Use system time" toggle let the operator override the host's clock so
/// session timestamps, sequencer cadences, and diagnostic dumps reflect
/// the **observatory's** local time, not the laptop's. The two relevant
/// use cases the toggle was built for:
///
///   1. **Remote-observatory** — A hosted scope at a remote site emits
///      logs in the site's local time even when the controlling laptop
///      sits elsewhere. The operator picks the site's IANA TZ and toggles
///      "Use system time" off.
///   2. **Travelers** — An astrophotographer flies a scope to a star
///      party in a different state. Their laptop's TZ is correct but the
///      saved sequences/profiles were authored in their home TZ; setting
///      "Use system time" on uses the new local time automatically.
///
/// `Clock.now()` returns whichever wall-clock the user asked for; call
/// sites that need a stable monotonic clock should still use
/// `DateTime.now()` directly (the system clock is not what the user
/// chose — it is what the OS scheduler counts on).
abstract class Clock {
  /// The current time **as the operator wants to read it** — field values
  /// (hour, minute…) in the chosen zone, for putting on screen.
  ///
  /// This is a rendering, not an instant. Dart has no arbitrary-offset
  /// `DateTime`, so [FixedOffsetClock] returns the shifted fields tagged
  /// `isUtc: false`; the host then treats them as its own local time.
  /// `now().toUtc()`, `now().millisecondsSinceEpoch` and
  /// `now().difference(someRealTimestamp)` are therefore all wrong by the
  /// chosen offset *plus* the host's. Use [nowUtc] for any of those.
  DateTime now();

  /// The current instant, as UTC — always the true moment, whatever zone the
  /// operator picked.
  ///
  /// Everything that stores, compares, subtracts or serialises a time wants
  /// this: capture timestamps, filenames, scheduler evaluation, staleness
  /// checks. Only code putting digits on a screen wants [now].
  DateTime nowUtc();

  /// How far ahead of UTC the chosen zone runs.
  ///
  /// Consumers that do their own zone arithmetic against a real instant (the
  /// scheduler evaluates time-window constraints in site-local minutes) need
  /// the offset rather than a pre-rendered `DateTime`.
  Duration get utcOffset;

  /// Translate an arbitrary [DateTime] (assumed UTC) into the user's
  /// chosen clock zone. Useful when the underlying source is UTC-based
  /// (FITS headers, scheduler timestamps) and the UI needs the
  /// operator-local rendering.
  DateTime fromUtc(DateTime utc);
}

class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();

  @override
  Duration get utcOffset => DateTime.now().timeZoneOffset;

  @override
  DateTime fromUtc(DateTime utc) => utc.toLocal();
}

/// Clock that returns `DateTime.now()` shifted by a fixed offset relative
/// to UTC. Constructed when the user picks a non-system timezone.
class FixedOffsetClock implements Clock {
  @override
  final Duration utcOffset;
  final String label;

  const FixedOffsetClock({required this.utcOffset, required this.label});

  /// Build a wall-clock `DateTime` whose fields (year, month, day, hour…)
  /// match the calendar time at the configured offset.
  ///
  /// Why: we deliberately return a non-UTC `DateTime` constructed from
  /// the field values rather than rebasing through epoch millis. Epoch
  /// millis carries no offset information; rebasing back as
  /// `isUtc: false` would re-apply the host's local offset and undo
  /// our shift. Using the field-based constructor preserves the
  /// fields-as-displayed semantic the rest of the app expects when it
  /// stringifies these values.
  DateTime _wallClock(DateTime utc) {
    final shifted = utc.add(utcOffset);
    return DateTime(
      shifted.year,
      shifted.month,
      shifted.day,
      shifted.hour,
      shifted.minute,
      shifted.second,
      shifted.millisecond,
      shifted.microsecond,
    );
  }

  @override
  DateTime now() => _wallClock(DateTime.now().toUtc());

  /// Deliberately *not* derived from [now]: `_wallClock` throws the offset
  /// away by re-tagging the shifted fields as host-local, so rebasing it
  /// would double-count. The instant is the same whatever zone you display
  /// it in.
  @override
  DateTime nowUtc() => DateTime.now().toUtc();

  @override
  DateTime fromUtc(DateTime utc) {
    final asUtc = utc.isUtc ? utc : utc.toUtc();
    return _wallClock(asUtc);
  }
}

/// The active clock per user settings.
///
/// Default falls back to [SystemClock] whenever settings are loading,
/// the user has chosen "use system time", or the configured TZ label
/// cannot be parsed. An unparseable label is logged here (once per rebuild
/// of this provider, not once per `now()`), because a silent fallback makes
/// the Timezone picker look applied while every timestamp stays on host
/// local time.
final clockProvider = Provider<Clock>((ref) {
  final settings = ref.watch(appSettingsProvider).valueOrNull;
  if (settings == null || settings.useSystemTime) {
    return const SystemClock();
  }
  final offset = _parseTimezoneOffset(settings.timezone);
  if (offset == null) {
    // An unparseable TZ falls back to the system clock so the app keeps
    // working, and logs: the fallback is otherwise indistinguishable from
    // "use system time" and the rejected picker value stays invisible.
    ref
        .read(loggingServiceProvider)
        .warning(
          'Timezone "${settings.timezone}" is not a recognised UTC offset; '
          'falling back to host system time. Choose a "UTC" or "UTC±HH:MM" '
          'entry in Settings → Location → Timezone.',
          source: 'clockProvider',
        );
    return const SystemClock();
  }
  return FixedOffsetClock(utcOffset: offset, label: settings.timezone);
});

// Shared tick stream — one timer per cadence, multiplexed across the app.

/// Standard cadences exposed by [tickerProvider]. Adding a new cadence is a
/// matter of adding an enum value and the corresponding [Duration] in
/// [_tickerInterval]; the provider machinery scales automatically.
///
/// The point of having a *fixed* set of cadences (rather than an arbitrary
/// `Duration` family) is so that a hundred widgets asking for "give me a
/// 1 s tick" share the *same* underlying timer. A `Provider.family` keyed
/// on `Duration` would still de-duplicate by value, but the enum keeps the
/// vocabulary small and makes it obvious in autocomplete what the
/// supported cadences are.
enum TickerCadence {
  /// One tick per second. Used by per-frame countdown displays and live
  /// exposure progress overlays where sub-second drift is irrelevant.
  oneSecond,

  /// One tick every five seconds. Used by guiding RMS smoothers and
  /// safety-status freshness indicators.
  fiveSeconds,

  /// One tick every thirty seconds. Used by sky/AltAz recomputation,
  /// integration totals, and other slow-moving telemetry. Altitude only
  /// changes ~0.25°/min so 30 s is fine for any altitude/azimuth UI.
  thirtySeconds,
}

Duration _tickerInterval(TickerCadence cadence) {
  switch (cadence) {
    case TickerCadence.oneSecond:
      return const Duration(seconds: 1);
    case TickerCadence.fiveSeconds:
      return const Duration(seconds: 5);
    case TickerCadence.thirtySeconds:
      return const Duration(seconds: 30);
  }
}

/// A shared interval-tick stream keyed by [TickerCadence].
///
/// One timer per cadence, shared by every consumer of it: panels on the same
/// cadence redraw on the same boundary rather than each waking the app at its
/// own millisecond offset.
///
/// Each cadence is a `StreamProvider` (only three cells) that emits the
/// current `DateTime` once on subscription and then at the requested cadence.
/// The underlying timer is created on first listen and torn down when the
/// provider is disposed (no listeners). New listeners join an in-flight
/// cadence without resetting the phase.
final tickerProvider = StreamProvider.family<DateTime, TickerCadence>((
  ref,
  cadence,
) {
  final interval = _tickerInterval(cadence);
  late StreamController<DateTime> controller;
  AlignedTicker? timer;
  controller = StreamController<DateTime>.broadcast(
    onListen: () {
      // Emit synchronously so the first build of a consumer doesn't have
      // to wait for the first interval before it gets a value. Without
      // this the consumer would render `AsyncLoading` until the timer
      // fires, which produces a visible "—" → "12s remaining" flicker.
      controller.add(DateTime.now());
      // Aligned to the cadence's wall-clock boundary, so this shared tick lands
      // in the same frame as the app's other clocks instead of costing a
      // full-window frame on a phase of its own. See [AlignedTicker].
      timer ??= AlignedTicker(interval, () {
        if (!controller.isClosed) controller.add(DateTime.now());
      });
    },
    onCancel: () {
      timer?.cancel();
      timer = null;
    },
  );
  ref.onDispose(() {
    timer?.cancel();
    controller.close();
  });
  return controller.stream;
});

/// Parse a timezone label as supplied by the Settings → Location dropdown.
///
/// Supports two formats so the existing settings dropdown contents work
/// without migration:
///   * `UTC` → zero offset
///   * `UTC+05:30`, `UTC-08:00`, `UTC+5`, `UTC-8` → signed offset
///
/// Returns null for unrecognised input.
Duration? _parseTimezoneOffset(String label) {
  final normalized = label.trim().toUpperCase();
  if (normalized == 'UTC') return Duration.zero;
  if (!normalized.startsWith('UTC')) return null;
  final rest = normalized.substring(3);
  if (rest.isEmpty) return null;
  final sign = rest[0];
  if (sign != '+' && sign != '-') return null;
  final numericPart = rest.substring(1);
  int hours = 0;
  int minutes = 0;
  if (numericPart.contains(':')) {
    final parts = numericPart.split(':');
    if (parts.length != 2) return null;
    hours = int.tryParse(parts[0]) ?? -1;
    minutes = int.tryParse(parts[1]) ?? -1;
  } else {
    hours = int.tryParse(numericPart) ?? -1;
  }
  if (hours < 0 || minutes < 0) return null;
  final total = Duration(hours: hours, minutes: minutes);
  return sign == '-' ? -total : total;
}
