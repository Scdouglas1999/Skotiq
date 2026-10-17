import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:file_selector/file_selector.dart';

import '../../utils/confirm_dialog.dart';
import '../../utils/device_format_utils.dart';
import '../../utils/exported_file_reveal.dart';
import '../../utils/snackbar_helper.dart';

part 'equipment_profiles_screen_parts/screen_shell.dart';
part 'equipment_profiles_screen_parts/profile_list.dart';
part 'equipment_profiles_screen_parts/profile_details.dart';
part 'equipment_profiles_screen_parts/profile_details_rendering.dart';
part 'equipment_profiles_screen_parts/profile_details_helpers.dart';
part 'equipment_profiles_screen_parts/profile_controls.dart';
