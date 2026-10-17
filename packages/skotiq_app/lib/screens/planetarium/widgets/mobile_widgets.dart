import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:intl/intl.dart';
import '../../../utils/coordinate_format_utils.dart';
import '../../../widgets/tutorial_keys/planetarium_keys.dart';
import '../planetarium_screen.dart';
import '../providers/device_orientation_provider.dart';

part 'mobile_widgets/top_overlay.dart';
part 'mobile_widgets/view_and_slew_controls.dart';
part 'mobile_widgets/bottom_info_and_hud.dart';
part 'mobile_widgets/object_info_content.dart';
part 'mobile_widgets/search_sheet.dart';
part 'mobile_widgets/compass_calibration_dialog.dart';

double _mobileTouchOuter(BuildContext context) =>
    AdaptiveSizing.of(context).minTouchTarget;

double _mobileTouchInner(BuildContext context) =>
    (_mobileTouchOuter(context) * 0.64).clamp(24.0, 30.0);

double _mobileSearchTileExtent(BuildContext context) =>
    _mobileTouchOuter(context) + 24;
