// The Framing column's composite controls: exact rotation entry, the preview
// field of view, the equipment-FOV overlay, and the mosaic grid controls.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'package:skotiq_app/utils/snackbar_helper.dart';
import 'framing_panel_parts.dart';

part 'framing_controls_parts/_rotation_fields.dart';
part 'framing_controls_parts/_fov_controls.dart';
part 'framing_controls_parts/_mosaic_controls.dart';
