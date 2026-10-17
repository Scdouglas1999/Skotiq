import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../dashboard/dashboard_screen.dart';
import 'first_night_wizard.dart';

/// Route widget for `/tutorial/first-night`.
///
/// Renders the dashboard screen as the backdrop and opens the
/// [FirstNightWizard] dialog on top in the first post-frame callback.
/// When the dialog closes (by any path — Done, Skip Forever, Show on Next
/// Launch, or close button) this widget redirects to /dashboard so the
/// user doesn't get stuck on a one-shot route.
///
/// Why a backdrop instead of a blank scaffold: the wizard is a dialog,
/// not a full-screen page. Rendering the dashboard underneath means the
/// user sees the actual app the moment the dialog appears — they're
/// already oriented when they click "Skip", and "Show me" deep-links into
/// other screens feel like seamless transitions rather than escapes from
/// a separate tutorial mode.
class FirstNightWizardRoute extends ConsumerStatefulWidget {
  const FirstNightWizardRoute({super.key});

  @override
  ConsumerState<FirstNightWizardRoute> createState() =>
      _FirstNightWizardRouteState();
}

class _FirstNightWizardRouteState extends ConsumerState<FirstNightWizardRoute> {
  bool _hasOpened = false;

  @override
  void initState() {
    super.initState();
    // Post-frame so the Navigator stack is fully laid out before we push
    // the dialog. If we called showDialog synchronously in initState the
    // route transition animation and the dialog's barrier fade would
    // collide.
    WidgetsBinding.instance.addPostFrameCallback((_) => _openWizard());
  }

  Future<void> _openWizard() async {
    if (_hasOpened) return;
    _hasOpened = true;
    await FirstNightWizard.show(context);
    if (!mounted) return;
    // After the dialog closes, return to the dashboard so the user lands
    // on a normal screen instead of this empty backdrop route.
    context.go('/dashboard');
  }

  @override
  Widget build(BuildContext context) {
    // Show the dashboard underneath the dialog so the user has visual
    // context. The dialog is barrier-dismissible: false so they can't
    // click through to the dashboard accidentally.
    return const DashboardScreen();
  }
}
