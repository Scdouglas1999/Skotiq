import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import 'snackbar_helper.dart';

/// Make a just-written export file reachable by the operator.
///
/// Every in-app export writes to `resolveSkotiqDocumentsDirectory()`. On
/// desktop that path is user-accessible, so an `Exported to <path>` snackbar
/// is actionable. On a PHONE/TABLET it is the app's PRIVATE sandbox — the same
/// snackbar named a file the user can never open in Files/Photos/Drive. This
/// helper closes that gap: on mobile it hands the file to the system share
/// sheet (Save to Files, email, Drive, …); on desktop it keeps the path
/// snackbar. Call it immediately after the file is written.
///
/// [subject] is the share-sheet title / email subject on mobile.
/// [desktopMessage] overrides the desktop snackbar (defaults to a path line).
/// [desktopDuration] overrides how long that snackbar stays up — long paths
/// (e.g. a diagnostic dump the user has to copy into a bug report) need more
/// than the default few seconds.
Future<void> revealExportedFile(
  BuildContext context,
  String filePath, {
  String subject = 'Skotiq export',
  String? desktopMessage,
  Duration? desktopDuration,
}) async {
  // The host OS, not defaultTargetPlatform: widget tests report Android there.
  if (hostHasShareSheet(Platform.operatingSystem)) {
    await Share.shareXFiles([XFile(filePath)], subject: subject);
    return;
  }
  if (!context.mounted) return;
  context.showSuccessSnackBar(
    desktopMessage ?? 'Exported to: $filePath',
    duration: desktopDuration,
  );
}

/// Whether [revealExportedFile] hands a file to the share sheet on the host
/// whose `Platform.operatingSystem` is [operatingSystem].
@visibleForTesting
bool hostHasShareSheet(String operatingSystem) =>
    operatingSystem == 'android' || operatingSystem == 'ios';

/// Whether this platform has a system share sheet `share_plus` can drive.
/// Windows and Linux have none. macOS has one; [macOS] says whether the
/// caller uses it there.
bool platformHasShareSheet({required bool macOS}) =>
    switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.android => true,
      TargetPlatform.macOS => macOS,
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.fuchsia =>
        false,
    };
