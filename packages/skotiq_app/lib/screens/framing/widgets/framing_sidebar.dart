// The Framing side column: the pinned target search, then the Target,
// Telescope, Sequence, Camera, Rotation, Sky view and Mosaic sections. Each
// section is a [FramingPanelSection], so the column reads as one panel in the
// Tonight right-panel style.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show AstronomyCalculations;

import 'package:skotiq_app/utils/snackbar_helper.dart';
import '../../../widgets/tutorial_keys/framing_keys.dart';
import '../altitude_chart.dart';
import '../framing_search_provider.dart';
import 'framing_controls.dart';
import 'framing_panel_parts.dart';

part 'framing_sidebar/target_and_equipment.dart';
part 'framing_sidebar/controls_and_status.dart';
part 'framing_sidebar/mosaic_and_actions.dart';
