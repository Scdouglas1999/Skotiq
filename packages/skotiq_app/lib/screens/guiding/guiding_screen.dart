import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_app/widgets/phd2_connection_dialog.dart';
import 'package:skotiq_app/widgets/phd2/guide_controls_panel.dart';
import 'package:skotiq_app/widgets/phd2/guide_target_display.dart';
import 'package:skotiq_app/utils/phd2_helper.dart';
import 'package:skotiq_app/utils/confirm_dialog.dart';
import '../../widgets/tutorial_keys/guiding_keys.dart';

part 'guiding_screen_parts/state_fields.dart';
part 'guiding_screen_parts/desktop_sections.dart';
part 'guiding_screen_parts/mobile_sections.dart';
part 'guiding_screen_parts/actions.dart';

/// Why Pause is unavailable under Skotiq's own guider.
///
/// Pause is a PHD2 command, so the built-in guider has none. Without this
/// reason on screen the button is simply inert — nothing changes in the UI, the
/// status bar or the log — and the operator cannot tell whether corrections
/// have been suspended.
const String kBuiltinGuiderNoPauseReason =
    'Pause is a PHD2 feature. The built-in guider has no pause — '
    'use Stop to suspend guiding.';

/// Full guiding interface (06 §Guiding).
///
/// A [PageHeader] over three columns: the guide star, the target display and
/// star statistics on the left; the guide graph in the middle; the controls,
/// calibration and Brain settings in a [SidePanel] on the right. Below the
/// shell's layout breakpoint the columns reflow to the graph over a tabbed
/// body whose tabs live in the page header.
class GuidingScreen extends ConsumerStatefulWidget {
  const GuidingScreen({super.key});

  @override
  ConsumerState<GuidingScreen> createState() => _GuidingScreenState();
}

class _GuidingScreenState extends ConsumerState<GuidingScreen>
    with
        SingleTickerProviderStateMixin,
        _GuidingStateFields,
        _GuidingActions,
        _GuidingDesktopSections,
        _GuidingMobileSections {
  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: _GuidingMobileSections._narrowTabs.length,
      vsync: this,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final isConnected = ref.watch(phd2ConnectedProvider);
    final phd2State = ref.watch(phd2StateProvider);
    final guideStats = ref.watch(guideStatsProvider);

    ref.watch(phd2ControllerProvider);

    // Seed the settle/dither controls from the canonical persisted settings the
    // first time they are available. Watching the provider means a fresh screen
    // (post-reconstruction) re-hydrates from the persisted values.
    final settingsAsync = ref.watch(appSettingsProvider);
    final settings = settingsAsync.valueOrNull;
    if (settings != null) {
      _hydrateGuidingSettings(settings);
    }

    // A phone is a phone in either orientation — a large phone held in
    // landscape is ~932 px wide yet must NOT get the three columns (they
    // overflow). Branch on the shortest side so portrait AND landscape phones
    // both take the reflowed layout, and on the shell breakpoint so a narrow
    // desktop window reflows too.
    final narrow = _isNarrowViewport(context);
    // PageHeader gives the tabs their own row only below ITS breakpoint. A
    // phone in landscape (844 x 390) is above that yet still takes the
    // reflowed body, and squeezing the tab strip into the header row there
    // scrolls the last tab out of reach — so it gets the `bottom` slot.
    final headerIsNarrow = MediaQuery.sizeOf(context).width <
        ShellChromeMetrics.shellLayoutBreakpoint;

    return Scaffold(
      // Connection/settings inputs live in modal dialogs that handle their
      // own IME insets. Resizing the complex guiding dashboard behind the
      // modal can make its fixed chrome overflow in short landscape viewports
      // even though the user cannot interact with it.
      resizeToAvoidBottomInset: false,
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            PageHeader(
              key: GuidingTutorialKeys.statusBar,
              icon: SkotiqIcons.guider,
              title: 'Guiding',
              // Below the breakpoint the header keeps the title, the state
              // chip and the two actions; the connection sentence and the
              // button labels are the content that goes, not the type size.
              context: narrow ? null : _connectionLabel(isConnected),
              tabs: narrow && headerIsNarrow ? _buildNarrowTabs() : null,
              bottom:
                  narrow && !headerIsNarrow ? _buildTabStripRow(colors) : null,
              actions: _buildHeaderActions(isConnected, phd2State, narrow),
            ),
            if (settingsAsync.hasError)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  SkotiqTokens.space2xl,
                  SkotiqTokens.spaceMd,
                  SkotiqTokens.space2xl,
                  0,
                ),
                child: SkotiqBanner(
                  title: 'Guiding defaults unavailable.',
                  message: 'Settle and dither edits are disabled. '
                      '${settingsAsync.error}',
                  tone: BannerTone.error,
                  action: SkotiqButton(
                    label: 'Retry',
                    variant: ButtonVariant.secondary,
                    size: ButtonSize.small,
                    onPressed: () => ref.invalidate(appSettingsProvider),
                  ),
                ),
              ),
            Expanded(
              child: narrow
                  ? _buildMobileLayout(
                      colors, isConnected, phd2State, guideStats)
                  : _buildDesktopLayout(
                      colors, isConnected, phd2State, guideStats),
            ),
          ],
        ),
      ),
    );
  }

  /// The page header's actions: the guider state chip, the ONE connect action
  /// and the settings icon button (06 §Guiding).
  ///
  /// Below the shell breakpoint the connect action collapses to an icon
  /// button: at 360 px the labelled button, the chip and the title cannot
  /// share the row, and 07 says reduce content rather than shrink type.
  List<Widget> _buildHeaderActions(
    bool isConnected,
    Phd2State phd2State,
    bool narrow,
  ) {
    final guiderState = ref.watch(guiderStateProvider);
    final guiderId = guiderState.deviceId;
    final isPhd2Guider = guiderId == null || isPhd2DeviceId(guiderId);
    final connecting =
        guiderState.connectionState == DeviceConnectionState.connecting;

    final (IconData icon, String label, VoidCallback? onPressed) =
        _connectAction(isConnected, isPhd2Guider, connecting);

    return [
      SkotiqChip(
        label: _getStateLabel(phd2State),
        tone: _getStateTone(phd2State),
        dot: true,
      ),
      if (narrow)
        SkotiqIconButton(
          key: GuidingTutorialKeys.connectBtn,
          icon: icon,
          tooltip: label,
          onPressed: onPressed,
        )
      else
        SkotiqButton(
          key: GuidingTutorialKeys.connectBtn,
          label: label,
          icon: icon,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          // While a connect is in flight the guider sits in the `connecting`
          // state — a disabled, spinning affordance so a second tap cannot
          // launch/socket PHD2 again (connect is not abortable mid-flight).
          isLoading: connecting,
          onPressed: onPressed,
        ),
      SkotiqIconButton(
        icon: SkotiqIcons.settings,
        tooltip: isPhd2Guider ? 'PHD2 connection settings' : 'Guider settings',
        onPressed: () =>
            isPhd2Guider ? _showConnectionDialog() : context.go('/equipment'),
      ),
    ];
  }

  /// The one connect-side action for the current guider state.
  (IconData, String, VoidCallback?) _connectAction(
    bool isConnected,
    bool isPhd2Guider,
    bool connecting,
  ) {
    if (connecting) {
      return (SkotiqIcons.connected, 'Connecting\u2026', null);
    }
    if (!isConnected && isPhd2Guider) {
      return (
        SkotiqIcons.connected,
        'Connect',
        () => connectPhd2(ref, context: context),
      );
    }
    if (isConnected) {
      return (
        LucideIcons.plugZap,
        'Disconnect',
        () => isPhd2Guider
            ? disconnectPhd2(ref, context: context)
            : _disconnectActiveGuider(),
      );
    }
    return (
      SkotiqIcons.guider,
      'Equipment',
      () => context.go('/equipment'),
    );
  }
}
