import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether the operator chose to move the mount while the guider is not
/// answering ([GuiderNotAnsweringException]). The question is asked once: the
/// answer covers the GoTo it was asked for and the centering slews that
/// follow it, and is withdrawn when the guider answers a move again.
final guiderSilentMoveAcceptedProvider = StateProvider<bool>((ref) => false);
