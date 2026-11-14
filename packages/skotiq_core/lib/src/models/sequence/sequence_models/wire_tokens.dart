part of '../sequence_models.dart';

// Enum tokens shared by both node stores ([NodeStore]). Encoding emits each
// store's historical bytes, since changing them would strand every sequence
// already saved; decoding accepts every historical spelling.

/// Resolve [raw] against the `name` of one of [values], case-insensitively.
///
/// Returns null when [raw] is not a string or matches nothing — callers decide
/// whether that means "absent" or "fall back to a default".
T? enumFromWire<T extends Enum>(List<T> values, Object? raw) {
  if (raw is! String) return null;
  final token = raw.toLowerCase();
  for (final value in values) {
    if (value.name.toLowerCase() == token) return value;
  }
  return null;
}

/// [enumFromWire] with a default for the absent/unknown case.
T enumFromWireOr<T extends Enum>(List<T> values, Object? raw, T fallback) =>
    enumFromWire(values, raw) ?? fallback;

/// The legacy spelling of [AutofocusMethod.quadratic], still on disk in older
/// sequences and files.
const String kAutofocusQuadraticLegacyToken = 'parabolic';

AutofocusMethod autofocusMethodFromWire(Object? raw) {
  if (raw is String && raw.toLowerCase() == kAutofocusQuadraticLegacyToken) {
    return AutofocusMethod.quadratic;
  }
  return enumFromWireOr(AutofocusMethod.values, raw, AutofocusMethod.vCurve);
}

/// The DB codec's token for [RecoveryActionType.continueExecution]. The file
/// codec writes the enum name instead; both are read back by
/// [recoveryActionFromWire].
const String kRecoveryContinueDbToken = 'continue';

String recoveryActionToDbWire(RecoveryActionType action) =>
    action == RecoveryActionType.continueExecution
    ? kRecoveryContinueDbToken
    : action.name;

String recoveryActionToFileWire(RecoveryActionType action) => action.name;

/// Read a recovery action written by either codec.
///
/// [fallback] stays per-format on purpose: an unrecognised token has always
/// meant `continueExecution` to the DB reader and `retry` to the file reader,
/// and quietly changing what a corrupt node does at 3am is not a cleanup.
RecoveryActionType recoveryActionFromWire(
  Object? raw, {
  required RecoveryActionType fallback,
}) {
  if (raw is String && raw.toLowerCase() == kRecoveryContinueDbToken) {
    return RecoveryActionType.continueExecution;
  }
  return enumFromWireOr(RecoveryActionType.values, raw, fallback);
}

/// Read a NotificationNode's explicit-transport override.
///
/// Absent or empty list → null (inherit the matrix `custom` row). Unknown
/// transport keys are dropped rather than rejected: a newer build may name a
/// transport this one does not ship.
List<NotificationTransportKind>? explicitTransportsFromWire(Object? raw) {
  if (raw is! List) return null;
  final out = <NotificationTransportKind>[];
  for (final entry in raw) {
    if (entry is String) {
      final transport = NotificationTransportKind.fromStorageKey(entry);
      if (transport != null) out.add(transport);
    }
  }
  return out.isEmpty ? null : out;
}
