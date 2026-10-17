import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bumped on every profile mutation so a delete's Undo cannot race a later
/// edit: an Undo whose epoch no longer matches is refused with a reason.
///
/// Lives in the provider container, not in the Equipment screen's state,
/// because the Undo offer outlives the screen (see `restoreDeletedProfile`),
/// and in its own file because the device panels write profiles too — a part
/// of `equipment_screen.dart` could not be reached from there.
final profileMutationEpochProvider = StateProvider<int>((ref) => 0);
