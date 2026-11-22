import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/errors.dart';

import '../../../../utils/darkroom_navigation.dart';
import '../../../../utils/snackbar_helper.dart';
import 'live_stack_darkroom_provider.dart';

/// Open in Darkroom from a live stack view: promotes the [filterKey] stack
/// and pushes the editor on it, or says why it cannot.
///
/// [setBusy] is told when the promotion starts and ends, so the view can
/// disable its button meanwhile.
Future<void> openLiveStackInDarkroom(
  BuildContext context,
  WidgetRef ref,
  String filterKey, {
  required void Function(bool busy) setBusy,
}) async {
  final refusal = darkroomHostOnlyRefusal(ref);
  if (refusal != null) {
    context.showInfoSnackBar(refusal);
    return;
  }
  setBusy(true);
  try {
    final promoted = await promoteLiveStackToDarkroom(
      ref: ref,
      filterKey: filterKey,
    );
    if (!context.mounted) return;
    unawaited(
      context.push(
        darkroomEditLocation(
          masterId: promoted.masterId,
          recipeId: promoted.recipeId,
        ),
      ),
    );
  } catch (error) {
    if (!context.mounted) return;
    context.showErrorSnackBar(
      'Could not open in Darkroom: ${userFacingError(error)}',
    );
  } finally {
    if (context.mounted) setBusy(false);
  }
}
