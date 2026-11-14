import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'link_rig_dialog.dart';

/// Opens this app's one way of linking to a rig. On the desktop that is the
/// link dialog (find a rig or type its address, pair, restart linked); the
/// phone's shell replaces it with its connection screen, which runs the
/// phone's connect flow.
final openRigConnectProvider = StateProvider<void Function(BuildContext)>(
  (ref) => (context) => unawaited(showLinkRigDialog(context)),
);
