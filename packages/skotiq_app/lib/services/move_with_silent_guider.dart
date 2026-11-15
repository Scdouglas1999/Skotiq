import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Asks the operator whether a GoTo should go ahead although the guider is
/// not answering and cannot be stopped first. The app's startup gives it the
/// dialog; a process with no screen to ask on answers no.
final moveWithSilentGuiderAskProvider = Provider<Future<bool> Function()>(
  (ref) => () async => false,
);
