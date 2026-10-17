/// Type-safe cast helpers for the Dart <-> Rust FFI boundary.
///
/// The Rust side has many unchecked `as` numeric casts (where `From`/`TryFrom`
/// would be safer). On the Dart side the
/// corresponding risk lives at JSON / dynamic-payload deserialization where
/// `value as Type` will throw a bare `TypeError` if the runtime type does not
/// match.
///
/// These helpers replace `value as T` with a checked cast that throws a
/// structured [CastFailureException] carrying:
///   * the field/context label (so the failure points at the right call site)
///   * the expected type
///   * the actual runtime type and value
///
/// Why a dedicated exception class:
///   - Bare `TypeError` is hard to catch without unsafe `dynamic` typing.
///   - A structured exception preserves the stack trace AND the context; a
///     silent fallback would hand the caller a value the payload never held.
///
/// Use [safelyCast] / [safelyCastOpt] at hand-written FFI boundaries where the
/// payload type is not statically proven (PHD2 JSON-RPC responses, ip-api.com
/// payloads, free-form event maps).
///
/// Do NOT use inside FRB-generated files — those are regenerated from Rust and
/// any local edits will be lost.
///
/// Lives in `skotiq_bridge` so the FFI-fallback layer (`bridge_stub.dart`)
/// can use it without depending on `skotiq_core`. The helper is re-exported
/// from `skotiq_core` for discoverability per task spec.
library;

/// Thrown when a checked cast at the FFI boundary fails.
///
/// Carries enough context to identify the offending field and the type
/// mismatch, replacing the bare `TypeError` raised by `value as T`.
class CastFailureException implements Exception {
  /// Human-readable label describing where the cast happened.
  ///
  /// Examples: `'phd2GetStarImage.result["frame"]'`,
  /// `'ip-api.com response["lat"]'`.
  final String context;

  /// The Dart type that was expected.
  final Type expectedType;

  /// The runtime type of the value that was actually present.
  final Type actualType;

  /// The actual value, truncated to a short representation. May be `null`.
  final String actualValueRepr;

  const CastFailureException({
    required this.context,
    required this.expectedType,
    required this.actualType,
    required this.actualValueRepr,
  });

  @override
  String toString() =>
      'CastFailureException($context): expected $expectedType, '
      'got $actualType (value=$actualValueRepr)';
}

/// Cast [value] to [T] or throw [CastFailureException] with [context].
///
/// Unlike `value as T`, this:
///   1. Throws a structured exception, not a bare `TypeError`.
///   2. Includes the call-site context so logs/crash reports identify the
///      offending field immediately.
///   3. Has uniform semantics for `null` — [T] must be nullable to allow it.
///
/// An unguarded `payload['key'] as String` on an FRB or JSON-RPC reply raises
/// a bare `TypeError` that names no key; this helper names the key instead.
T safelyCast<T>(Object? value, {required String context}) {
  if (value is T) return value;
  throw CastFailureException(
    context: context,
    expectedType: T,
    actualType: value.runtimeType,
    actualValueRepr: _shortRepr(value),
  );
}

/// Why: Dart's flow analysis does not promote `Object?` to a generic type
/// parameter `T` through an `is T` check inside a function returning `T?`.
/// We re-check with `is T` for safety, then use `value as T` knowing the
/// cast is guaranteed to succeed.

/// Like [safelyCast] but for fields that the producer may legitimately omit.
///
/// Returns `null` when [value] is `null`. If [value] is non-null but the wrong
/// type, throws [CastFailureException] — silent type drift is still a bug.
T? safelyCastOpt<T>(Object? value, {required String context}) {
  if (value == null) return null;
  if (value is T) return value as T;
  throw CastFailureException(
    context: context,
    expectedType: T,
    actualType: value.runtimeType,
    actualValueRepr: _shortRepr(value),
  );
}

/// Pull a numeric field out of a map and convert to `double`.
///
/// Tolerates the int/double slack that JSON and FRB both introduce (a value
/// serialized as `0` deserializes to `int`, while `0.0` deserializes to
/// `double`). Throws [CastFailureException] when the field is present but is
/// not a `num`.
///
/// Returns `null` when the key is absent — callers apply their own defaults at
/// the call site so the default is visible, not hidden in a helper.
double? safelyCastDoubleOpt(
  Map<String, Object?> map,
  String key, {
  required String contextPrefix,
}) {
  final raw = map[key];
  if (raw == null) return null;
  final n = safelyCastOpt<num>(raw, context: '$contextPrefix["$key"]');
  return n?.toDouble();
}

/// Pull a numeric field out of a map and convert to `int`.
///
/// Mirrors [safelyCastDoubleOpt]. JSON / FRB may send `42` or `42.0` — both
/// are accepted via `num.toInt()`. A value like `"42"` or `true` raises a
/// [CastFailureException] tagged with the field name.
int? safelyCastIntOpt(
  Map<String, Object?> map,
  String key, {
  required String contextPrefix,
}) {
  final raw = map[key];
  if (raw == null) return null;
  final n = safelyCastOpt<num>(raw, context: '$contextPrefix["$key"]');
  return n?.toInt();
}

String _shortRepr(Object? value) {
  if (value == null) return 'null';
  final s = value.toString();
  if (s.length <= 64) return s;
  return '${s.substring(0, 61)}...';
}
