import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'widgets/connected_device_card.dart';
import 'widgets/device_tile_width.dart';
import 'widgets/discovery_panel.dart';
import 'widgets/equipment_health_panel.dart';
import 'widgets/equipment_readiness_panel.dart';
import 'widgets/profile_scan_notice.dart';
import 'widgets/switch_control_card.dart';
import 'dialogs/profile_editor_dialog.dart';
import '../../router/equipment_route.dart';
import 'tabs/settings_tab.dart';
import 'profile_actions.dart';
import 'utils/connect_all_summary.dart';
import 'widgets/profiles_manager.dart';
import 'utils/profile_mutation_epoch.dart';
import 'utils/session_device_save.dart';
import '../../localization/skotiq_localizations.dart';
import '../../utils/device_type_ui.dart';
import '../../utils/snackbar_helper.dart';
import '../../tours/tour_target.dart';
import '../../widgets/run_status/recovery_banner.dart';
import 'package:skotiq_app/widgets/mount_guard/mount_guard_banner.dart';

export 'profile_actions.dart'
    show restoreDeletedProfile, selectedEquipmentProfileIdProvider;

part 'equipment_screen/layout_rail.dart';
part 'equipment_screen/progress_dashboard.dart';
part 'equipment_screen/sidebar_onboarding.dart';

/// Which page-header tab the Equipment screen is showing, as an index into
/// [EquipmentTab].
final equipmentTabIndexProvider = StateProvider<int>((ref) => 0);

/// Whether the right-hand side panel (profile, readiness, system health) is
/// collapsed. Desktop-only; below [ShellChromeMetrics.shellLayoutBreakpoint]
/// its content scrolls under the device grid instead.
final equipmentStatusRailCollapsedProvider =
    StateProvider<bool>((ref) => false);

/// Signature of the device-mismatch set the user last dismissed (✕). The
/// banner re-appears only when the *set* of mismatched devices changes (so a
/// genuinely new mismatch is never silently hidden). Session-scoped: cleared on
/// app restart, matching the "dismiss for this session" contract.
final dismissedMismatchSignatureProvider =
    StateProvider<String?>((ref) => null);

/// Body gutters, from the mockup: 20 px top/bottom, 24 px sides.
const EdgeInsets _bodyPadding = EdgeInsets.symmetric(
  horizontal: SkotiqTokens.space2xl,
  vertical: SkotiqTokens.spaceXl,
);

class EquipmentScreen extends ConsumerStatefulWidget {
  const EquipmentScreen({super.key, this.requestedTab});

  /// The tab a link asked for (`?tab=`); null leaves the tab as it was.
  final EquipmentTab? requestedTab;

  @override
  ConsumerState<EquipmentScreen> createState() => _EquipmentScreenState();
}

class _EquipmentScreenState extends ConsumerState<EquipmentScreen>
    with ProfileActions<EquipmentScreen> {
  @override
  void initState() {
    super.initState();
    _showRequestedTab();
  }

  @override
  void didUpdateWidget(EquipmentScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.requestedTab != oldWidget.requestedTab) _showRequestedTab();
  }

  void _showRequestedTab() {
    final tab = widget.requestedTab;
    if (tab == null) return;
    // A provider must not change while the tree that watches it is building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(equipmentTabIndexProvider.notifier).state = tab.index;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    watchProfileAuthority();
    final colors = SkotiqColors.of(context);
    final profilesAsync = ref.watch(equipmentProfilesProvider);
    if (profilesAsync.hasError) {
      return _EquipmentProfilesUnavailable(
        error: profilesAsync.error!,
        onRetry: () => _retryProfiles(ref),
      );
    }
    final profilesState = profilesAsync.valueOrNull;
    if (profilesState == null) {
      return const Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36));
    }
    if (profilesState.error != null) {
      return _EquipmentProfilesUnavailable(
        error: profilesState.error!,
        onRetry: () => _retryProfiles(ref),
      );
    }
    final profiles = List<EquipmentProfileModel>.from(profilesState.profiles)
      ..sort((a, b) {
        final orderCompare = a.sortOrder.compareTo(b.sortOrder);
        if (orderCompare != 0) return orderCompare;
        return a.name.compareTo(b.name);
      });
    final selectedProfileId = ref.watch(selectedEquipmentProfileIdProvider);
    final isRemoteMode = ref.watch(isRemoteModeProvider);

    // Check for first-time user (no profiles).
    //
    // REMOTE (slave) mode: never show the local first-run onboarding. A slave
    // controls the master's hardware and its profiles hydrate from the host's
    // SQLite over /api/profiles; before they arrive (or if the host genuinely
    // has none yet) the slave still renders the dashboard + discovery so the
    // operator can see connected devices and act — not a "create your first
    // profile" wizard that would write the slave's own empty DB. Local/host and
    // mobile first-run onboarding is unchanged (isRemoteMode false there).
    final firstRun = profiles.isEmpty && !isRemoteMode;

    final selectedProfile = selectedProfileId != null
        ? profiles.where((p) => p.id == selectedProfileId).firstOrNull
        : null;

    // NOT clamped to 0 during first run: Profiles and Optical train are
    // reachable before a profile exists, which is when someone most wants to
    // look at them.
    final tabIndex = ref.watch(equipmentTabIndexProvider);
    // Drives whether "Disconnect all" exists at all (see the header actions).
    final anythingConnected = ref.watch(rigDevicesProvider).connected > 0;
    // The profile's devices that are not up: "Connect all" is then the next
    // thing to do, and the header's one primary action.
    final activeProfile = ref.watch(activeEquipmentProfileProvider);
    final profileToConnect =
        ref.watch(offlineProfileDeviceNamesProvider).isNotEmpty
            ? activeProfile
            : null;
    // Below DESKTOP width, not the shell breakpoint: this header seats a
    // title, three tabs, a chip and two actions, and measured at 800 px the
    // labelled buttons overflow the row by 7.7 px — which shows up as a
    // truncated screen name, or a yellow overflow stripe in a test. The verbs
    // move into tooltips there.
    final headerWidth = MediaQuery.sizeOf(context).width;
    final narrowHeader = headerWidth < SkotiqTokens.breakpointDesktop;
    final phoneHeader = headerWidth < BreakpointTokens.breakpointPhone;

    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Equipment',
            icon: LucideIcons.plug,
            tabs: AdaptiveTabBar(
              horizontalPadding: 0,
              selectedIndex: tabIndex,
              onSelected: (index) =>
                  ref.read(equipmentTabIndexProvider.notifier).state = index,
              tabs: [
                AdaptiveTab(
                  label: 'Devices',
                  buttonKey: TourTarget.equipmentDevicesTab.key,
                ),
                AdaptiveTab(
                  label: 'Profiles',
                  count: profiles.isEmpty ? null : '${profiles.length}',
                ),
                const AdaptiveTab(label: 'Optical train'),
              ],
            ),
            actions: [
              // The chip goes below phone width: "4 connected · 1 unsaved" is
              // 150 px the 360 dp header does not have, and the instrument bar
              // plus the side panel's profile block both already say it.
              if (!phoneHeader) const _ConnectionStatusSummary(),
              // Below the shell breakpoint the two labels cost ~200 px the
              // 700 px header does not have, and the TITLE was the thing that
              // gave way ("Equi…"). The verbs move into the tooltips instead:
              // a truncated screen name is a worse trade than an icon.
              // On a PHONE the header carries the title and the tabs and
              // nothing else. A 32 px icon button is under Android's 48 dp tap
              // target, and there is nowhere in a 360 dp row to put two
              // 48 px ones beside a title and a chip — so both actions move to
              // where they already exist: "Scan for devices" is the drawer's
              // own "Scan all" (the same code path), and "Disconnect all" is in
              // the profile menu.
              //
              // The actions act on the Devices tab (Scan opens its discovery
              // drawer), and the Profiles tab has its own per-profile
              // Connect all / Disconnect all, so they are shown there only.
              // The one primary is "Connect all" while a profile device is
              // down; with the rig up nothing in the header is the next step.
              if (!phoneHeader && tabIndex == 0) ...[
                if (profileToConnect != null)
                  _HeaderAction(
                    label: 'Connect all',
                    icon: LucideIcons.plug,
                    primary: true,
                    iconOnly: narrowHeader,
                    onPressed: () => connectAllDevices(profileToConnect),
                  ),
                // Only when there IS something to disconnect. On a fresh
                // profile this offered to disconnect nothing, which reads as a
                // broken control rather than an empty rig.
                if (anythingConnected)
                  _HeaderAction(
                    label: 'Disconnect all',
                    icon: LucideIcons.unplug,
                    iconOnly: narrowHeader,
                    onPressed: disconnectAllDevices,
                  ),
                _HeaderAction(
                  key: TourTarget.equipmentScanButton.key,
                  label: 'Scan for devices',
                  icon: LucideIcons.search,
                  iconOnly: narrowHeader,
                  onPressed: () =>
                      ref.read(discoveryScanRequestProvider.notifier).state++,
                ),
              ],
            ],
          ),
          const MountGuardBanner(),
          Expanded(
            child: switch (tabIndex) {
              1 => const ProfilesManager(tutorialTargets: true),
              2 => const _OpticalTrainTab(),
              // First run owns the Devices tab only. The discovery drawer
              // is mounted BENEATH the empty state so the header's "Scan
              // for devices" has something to expand: before this it
              // bumped a provider no mounted widget was listening to, and
              // the primary action of the first screen did nothing at all.
              _ => firstRun
                  ? Column(
                      children: [
                        Expanded(
                          child: _FirstTimeOnboarding(
                            colors: colors,
                            onStartSetup: () => ref
                                .read(discoveryScanRequestProvider.notifier)
                                .state++,
                            onManualSetup: createEmptyProfile,
                          ),
                        ),
                        const DiscoveryPanel(),
                      ],
                    )
                  : _EquipmentMainColumn(
                      selectedProfile: selectedProfile,
                      onSettings: () => _showSettings(context),
                      onConnectAll: connectAllDevices,
                      onEditProfile: (profile) =>
                          showProfileEditor(context, profile),
                      onDisconnectAll: disconnectAllDevices,
                    ),
            },
          ),
        ],
      ),
    );
  }

  void _retryProfiles(WidgetRef ref) {
    ref.invalidate(allProfilesProvider);
    ref.invalidate(activeProfileProvider);
    ref.invalidate(equipmentProfilesProvider);
  }

  void _showSettings(BuildContext context) {
    // On a phone this becomes a full-screen route (settings is content-heavy);
    // on tablet/desktop it stays the familiar 700×500 dialog. The body manages
    // its own per-section scrolling, so the scaffold must not double-wrap it.
    if (Responsive.isPhone(context)) {
      showAdaptiveModal<void>(
        context: context,
        designWidth: 700,
        designHeight: 500,
        phoneMode: PhoneModalMode.fullScreen,
        builder: (modalContext) {
          final colors = SkotiqColors.of(modalContext);
          return Scaffold(
            backgroundColor: colors.background,
            appBar: AppBar(
              backgroundColor: colors.surface,
              title: Text(modalContext.l10n.text('equipmentSettingsTitle')),
              leading: SkotiqIconButton(
                icon: LucideIcons.x,
                tooltip: modalContext.l10n.text('commonClose'),
                onPressed: () => Navigator.of(modalContext).pop(),
              ),
            ),
            body: const SafeArea(child: EquipmentSettingsTab()),
          );
        },
      );
      return;
    }

    showDialog(
      context: context,
      builder: (dialogContext) => SkotiqDialog(
        title: dialogContext.l10n.text('equipmentSettingsTitle'),
        icon: LucideIcons.settings,
        width: 700,
        height: 500,
        // EquipmentSettingsTab manages its own scrolling per-section, so the
        // dialog scaffold must not double-wrap it in a SingleChildScrollView.
        scrollableBody: false,
        bodyPadding: EdgeInsets.zero,
        child: const EquipmentSettingsTab(),
      ),
    );
  }
}

/// One page-header action: a labeled button, or below desktop width an icon
/// button with the verb as its tooltip.
class _HeaderAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool primary;
  final bool iconOnly;
  final VoidCallback onPressed;

  const _HeaderAction({
    super.key,
    required this.label,
    required this.icon,
    required this.iconOnly,
    required this.onPressed,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    if (iconOnly) {
      return SkotiqIconButton(
        icon: icon,
        tooltip: label,
        selected: primary,
        onPressed: onPressed,
      );
    }
    return SkotiqButton(
      label: label,
      icon: icon,
      variant: primary ? ButtonVariant.primary : ButtonVariant.secondary,
      size: ButtonSize.small,
      onPressed: onPressed,
    );
  }
}

/// The Optical train tab: the profile editor's optical-train section, hosted
/// as a page instead of a dialog section.
class _OpticalTrainTab extends ConsumerWidget {
  const _OpticalTrainTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(activeEquipmentProfileProvider);
    if (profile == null) {
      return Center(
        child: EmptyState(
          icon: LucideIcons.aperture,
          title: 'No profile is active',
          body: 'Activate a profile in the Profiles tab to edit its telescope, '
              'focal length and aperture.',
          action: SkotiqButton(
            label: 'Open profiles',
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () =>
                ref.read(equipmentTabIndexProvider.notifier).state = 1,
          ),
        ),
      );
    }
    return ProfileEditorDialog(
      key: ValueKey<int?>(profile.id),
      profile: profile,
      mode: ProfileEditorMode.opticalTrainPage,
    );
  }
}

class _EquipmentProfilesUnavailable extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _EquipmentProfilesUnavailable({
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: EmptyState.compact(
        icon: LucideIcons.alertTriangle,
        title: 'Could not load equipment profiles',
        body: 'Skotiq could not read the equipment configuration. '
            'No profiles or setup actions are shown until it can be loaded.\n\n'
            '${userFacingError(error)}',
        action: SkotiqButton(
          label: 'Retry',
          icon: LucideIcons.refreshCw,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: onRetry,
        ),
      ),
    );
  }
}
