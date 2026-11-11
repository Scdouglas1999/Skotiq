import 'package:flutter/widgets.dart';
import '../../settings/settings_sections.dart';

/// Where the mount's meridian flips are set. Every run arms its own flip
/// trigger from these settings; the equipment screens hold none of their own.
const String kMeridianFlipSettingsPointer =
    'Every run flips the mount by itself. When to flip, recentering after the '
    'flip and settling are set in Settings > Sequencer > Meridian flip.';

/// Open Settings at the Sequencer section, which holds the meridian flip
/// settings.
void openMeridianFlipSettings(BuildContext context) {
  openSettings(context, SettingsSectionId.sequencer);
}
