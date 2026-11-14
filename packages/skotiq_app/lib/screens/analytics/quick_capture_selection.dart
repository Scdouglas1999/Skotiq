import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The session-picker entry that means "the frames shot outside any session".
///
/// A sentinel id gives the picker a third state, distinct from "auto" (follow
/// the live session, else the newest on record). Negative so it cannot collide
/// with `imaging_sessions.id`, a positive autoincrement key. Shared by the
/// Session, Science and Diagnostics pickers so the three cannot drift apart.
const int kQuickCaptureSessionSelection = -1;

/// What every picker calls that entry. One string, so a user who learns it on
/// Diagnostics recognises it on Session and Science.
const String kQuickCaptureSessionLabel = 'Quick captures (no session)';

/// The session the operator picked in an Analytics picker (Session, Science,
/// Diagnostics), [kQuickCaptureSessionSelection], or null for each tab's own
/// default. One pick for the three, so moving between tabs keeps the night.
final analyticsSessionPickProvider = StateProvider<int?>((ref) => null);
