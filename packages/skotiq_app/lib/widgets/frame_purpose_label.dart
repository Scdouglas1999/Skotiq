import 'package:skotiq_core/models.dart';

import '../localization/skotiq_localizations.dart';

/// What an autofocus, solve, centering or alignment frame is, for the label
/// over the main image: "Autofocus · point 5 of 13", "Plate solve",
/// "Centering · attempt 2 of 5". Null for a frame of the night.
String? framePurposeLabel(SkotiqLocalizations l10n, CapturedImageData image) {
  final step = image.purposeStep;
  final steps = image.purposeSteps;
  switch (image.purpose) {
    case FramePurpose.capture:
      return null;
    case FramePurpose.autofocus:
      return step != null && steps != null
          ? l10n.text(
              'nightCtrAfPoint',
              params: <String, String>{'point': '$step', 'total': '$steps'},
            )
          : l10n.text('nightCtrFrameAutofocus');
    case FramePurpose.plateSolve:
      return l10n.text('nightCtrFramePlateSolve');
    case FramePurpose.centering:
      return step != null && steps != null
          ? l10n.text(
              'nightCtrFrameCenteringAttempt',
              params: <String, String>{'attempt': '$step', 'total': '$steps'},
            )
          : l10n.text('nightCtrFrameCentering');
    case FramePurpose.polarAlignment:
      return step != null
          ? l10n.text(
              'nightCtrFramePolarPoint',
              params: <String, String>{'point': '$step'},
            )
          : l10n.text('nightCtrFramePolar');
  }
}
