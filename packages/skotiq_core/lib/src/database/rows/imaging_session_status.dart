import '../database.dart';
import '../../models/imaging/session_status.dart';

/// A session row's status, typed.
extension ImagingSessionStatus on ImagingSession {
  /// Null for a value no build writes.
  SessionStatus? get sessionStatus => SessionStatus.tryParse(status);
}
