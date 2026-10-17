// Template renderer for notification titles + bodies.
//
// Builds on the interpolation engine (see
// `models/sequence/interpolation_catalog.dart`). At runtime we have a
// real event context — target name, time, sequence id, frame counters —
// not just example values; this resolver consumes a context map and
// substitutes the `${name[:spec]}` placeholders inside a template
// string. Unknown variables fall back to the catalog `example` so the
// rendered notification still reads naturally instead of dumping
// `${target.name?}`.
//
// Why we don't call into Rust: the Rust evaluator (sequencer
// `expressions::evaluate`) is the source of truth for sequence-time
// interpolation. Notification rendering happens entirely in Dart, on a
// snapshot context that arrives via the event bus, so we can keep
// transport sends self-contained without round-tripping through FRB
// every time.

import '../../models/sequence/interpolation_catalog.dart';

/// Context key carrying the clause that names WHO ended a run (`by autopilot`,
/// `by the disk-space watchdog`, or empty for a safety abort nobody
/// commanded). The stop templates interpolate it; the router fills it from the
/// stop decision on the wire.
const String kStopCauseContextKey = 'stop.cause';

/// Context key carrying the run id a stop notification belongs to. Not for
/// display — it is how the router tells one run's stop episode from the next.
const String kStopRunIdContextKey = 'stop.run_id';

/// Build a per-event context map from a raw `SkotiqEvent.data` payload
/// plus any extra values the router knows. Keys use the same dotted form
/// as `interpolation_catalog.dart` (e.g. `target.name`, `time.now`).
///
/// Strings that look numeric stay strings; the format-spec branch parses
/// them back to numbers per-call. This matches how the Rust catalog
/// renders examples.
class NotificationContext {
  final Map<String, String> values;
  const NotificationContext(this.values);

  NotificationContext withDefaults({DateTime Function()? clock}) {
    // Always populate clock fields. The router writes them too, but
    // callers that build a context manually still get sensible values.
    final m = Map<String, String>.from(values);
    final now = (clock ?? DateTime.now)();
    m.putIfAbsent('time.now', () => now.toUtc().toIso8601String());
    m.putIfAbsent('time.local', () => now.toIso8601String());
    m.putIfAbsent('time.clock', () => formatOperatorClock(now));
    m.putIfAbsent(
      'time.date',
      () =>
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
    );
    return NotificationContext(m);
  }
}

/// Local wall-clock time as an operator reads it off a toast: `HH:mm`.
///
/// The built-in notification bodies interpolate `${time.clock}`, not
/// `${time.local}`, whose ISO-8601 rendering is a wire format in operator copy.
///
/// This is deliberately NOT a new entry in `interpolationCatalog`: that catalog
/// is Rust-canonical (`expressions/catalog.rs::variable_catalog`) with a
/// CI-enforced drift test, and `time.local` keeps its documented ISO-8601
/// meaning for user-authored templates. `time.clock` is populated by this
/// resolver for the built-in defaults.
///
/// 24-hour, matching every other clock rendering in the app (see
/// `sequence_time_estimator/node_durations.dart`, `pre_session_simulator.dart`):
/// an imaging session runs through midnight and AM/PM is the wrong vocabulary
/// for it.
String formatOperatorClock(DateTime when) {
  final local = when.isUtc ? when.toLocal() : when;
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// Render a template, substituting `${name[:spec]}` placeholders with
/// values from [context]. Unknown variables fall back to the catalog
/// `example` so the rendered string always reads cleanly.
String renderNotificationTemplate(
  String template,
  NotificationContext context, {
  DateTime Function()? clock,
}) {
  if (template.isEmpty) return '';
  final byName = {for (final v in interpolationCatalog) v.name: v};
  final ctx = context.withDefaults(clock: clock);

  final buf = StringBuffer();
  var i = 0;
  while (i < template.length) {
    // Doubled `$$` escapes `${`.
    if (i + 2 < template.length &&
        template[i] == r'$' &&
        template[i + 1] == r'$' &&
        template[i + 2] == '{') {
      buf.write(r'${');
      i += 3;
      continue;
    }
    if (i + 1 < template.length &&
        template[i] == r'$' &&
        template[i + 1] == '{') {
      final end = template.indexOf('}', i + 2);
      if (end < 0) {
        buf.write(template.substring(i));
        return buf.toString();
      }
      final body = template.substring(i + 2, end).trim();
      final colonIdx = body.indexOf(':');
      final name = colonIdx < 0 ? body : body.substring(0, colonIdx).trim();
      final spec = colonIdx < 0 ? null : body.substring(colonIdx + 1).trim();

      String? resolved = ctx.values[name];
      // Fall back to catalog example so the user sees *something* — the
      // notification is still useful even if the live context did not
      // populate that field.
      resolved ??= byName[name]?.example;

      if (resolved == null) {
        buf.write('\${$name?}');
      } else {
        buf.write(_applyFormatSpec(resolved, spec));
      }
      i = end + 1;
      continue;
    }
    buf.write(template[i]);
    i += 1;
  }
  return buf.toString();
}

String _applyFormatSpec(String value, String? spec) {
  if (spec == null || spec.isEmpty) return value;
  // Integer zero-pad: `0N`.
  final zeroPad = RegExp(r'^0(\d+)$').firstMatch(spec);
  if (zeroPad != null) {
    final width = int.parse(zeroPad.group(1)!);
    final asInt = int.tryParse(value);
    if (asInt != null) {
      return asInt.toString().padLeft(width, '0');
    }
  }
  // Fixed-point: `.Nf`.
  final fixed = RegExp(r'^\.(\d+)f$').firstMatch(spec);
  if (fixed != null) {
    final precision = int.parse(fixed.group(1)!);
    final asDouble = double.tryParse(value);
    if (asDouble != null) {
      return asDouble.toStringAsFixed(precision);
    }
  }
  return value;
}
