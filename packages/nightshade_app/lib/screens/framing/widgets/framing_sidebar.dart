import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:nightshade_ui/nightshade_ui.dart';
import 'package:nightshade_core/nightshade_core.dart';

import 'package:nightshade_app/utils/snackbar_helper.dart';
import '../../../widgets/tutorial_keys/framing_keys.dart';
import '../altitude_chart.dart';
import '../framing_search_provider.dart';
import 'framing_actions_panel.dart';
import '../../../widgets/slew_dropdown_button.dart';
import 'framing_controls.dart';
import 'framing_overlays.dart';

part 'framing_sidebar/target_and_equipment.dart';
part 'framing_sidebar/controls_and_status.dart';
part 'framing_sidebar/mosaic_and_actions.dart';
