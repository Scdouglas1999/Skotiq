part of '../flat_wizard_service.dart';

/// Clamp [value] into the inclusive `[lo, hi]` capability range when known.
/// A null [value] stays null (the camera/driver default is used).
int? _clampToRange(int? value, int? lo, int? hi) {
  if (value == null) return null;
  var v = value;
  if (lo != null && v < lo) v = lo;
  if (hi != null && v > hi) v = hi;
  return v;
}
