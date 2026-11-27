import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/confirm_dialog.dart';
import 'data/plan/plan_steps_provider.dart';

/// Asks before a Skip that ends the night: the step under way is the plan's
/// last imaging, so the run goes straight to its closing steps (a park moves
/// the mount) or ends. Every Skip control goes through this one gate.
///
/// Returns true when the skip may go ahead: it leaves imaging to do, or the
/// operator confirmed.
Future<bool> confirmSkipStep(BuildContext context, WidgetRef ref) async {
  final closing = ref.read(nightSkipEndsRunProvider);
  if (closing == null) return true;
  return ConfirmDialog.show(
    context: context,
    title: 'Skip the last imaging step?',
    message: closing.isEmpty
        ? 'Nothing comes after this step: skipping it ends the run.'
        : 'Nothing but the closing steps comes after this one, so skipping '
            'it ends the night now: ${closing.join(', ')}.',
    confirmLabel: 'Skip and end the night',
    isDestructive: true,
  );
}
