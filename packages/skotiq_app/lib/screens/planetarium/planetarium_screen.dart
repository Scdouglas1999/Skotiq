import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../services/finder_chart_service.dart';
import '../../services/fov_presets_sync_service.dart';
import '../../utils/plan_tonight_sequencer_helper.dart';
import 'providers/sequenced_object_ids_provider.dart';
import 'widgets/filter_sidebar.dart';
import 'widgets/top_overlay.dart';
import 'widgets/bottom_info_bar.dart';
import 'widgets/view_controls.dart';
import 'widgets/slew_controls.dart';
import 'widgets/search_header.dart';
import 'widgets/sidebar_tabs.dart';
import 'widgets/object_info_popup.dart';
import 'widgets/mobile_widgets.dart';
import 'widgets/mobile_overlay_layout.dart';
import 'providers/device_orientation_provider.dart';
import 'providers/finder_chart_catalog_provider.dart';
import '../../services/mount_command_service.dart';
import '../../utils/exported_file_reveal.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/tutorial_keys/planetarium_keys.dart';
import 'sky_imagery/planetarium_sky_imagery_layer.dart';
import 'sky_imagery/planetarium_sky_imagery_providers.dart';
import 'widgets/full_screen_sky_view.dart';
import 'widgets/sky_hotkey_scope.dart';
import 'widgets/star_catalog_fallback_banner.dart';
import 'widgets/star_chart_depth_notice.dart';
import 'widgets/redesign/command_bar.dart';
import 'widgets/redesign/layers_panel.dart';
import 'show_in_sky.dart';
import '../imaging/centering_dialog.dart';

part 'planetarium_screen/actions.dart';
part 'planetarium_screen/layouts.dart';
part 'planetarium_screen/local_widgets.dart';
part 'widgets/redesign/planetarium_shell.dart';
part 'planetarium_screen/sheets.dart';

/// Get display name and catalog tag for a DSO
/// Returns (displayName, catalogTag)
(String, String) getDsoDisplayInfo(DeepSkyObject dso) {
  // If it's a Messier object, use Messier number as name
  if (dso.isMessier) {
    final messierNum = dso.messierNumber;
    if (messierNum != null) {
      return (messierNum, 'M');
    }
  }

  // For non-Messier objects, use NGC/IC designation as name
  final ngcIc = dso.ngcIcDesignation;
  if (ngcIc != null) {
    if (ngcIc.startsWith('NGC')) {
      return (ngcIc, 'NGC');
    } else if (ngcIc.startsWith('IC')) {
      return (ngcIc, 'IC');
    }
  }

  // Fallback to id and extract catalog prefix
  if (dso.id.startsWith('NGC')) {
    return (dso.id, 'NGC');
  } else if (dso.id.startsWith('IC')) {
    return (dso.id, 'IC');
  } else if (dso.id.startsWith('M')) {
    return (dso.id, 'M');
  }

  // Last resort: use name and id
  return (dso.name, dso.id);
}

/// Scaffold-less planetarium body: the full sky-view shell (command bar +
/// dockable panels).
///
/// Hosted both inside Plan Tonight's "Sky" tab and by [PlanetariumScreen] (the
/// thin wrapper kept for the redirected `/planetarium` standalone route).
class PlanetariumView extends ConsumerStatefulWidget {
  const PlanetariumView({super.key});

  @override
  ConsumerState<PlanetariumView> createState() => _PlanetariumScreenState();
}

class _PlanetariumScreenState extends ConsumerState<PlanetariumView>
    with SingleTickerProviderStateMixin {
  final _searchController = TextEditingController();

  // Focus for the plan panel's search field. Owned here (not by SearchHeader)
  // because the command bar's "Search ⌘K" control lives outside that widget and
  // has to put the caret in the field: without this the button only opened the
  // panel and the next keystroke went nowhere.
  final _searchFocusNode = FocusNode(debugLabel: 'planetariumSearch');

  // Bumped by every Search command. The plan panel watches it and, on a change,
  // selects the Search tab and focuses the field. A counter rather than a bool
  // so a second press while the panel is already open still fires.
  int _searchFocusToken = 0;

  // Popup state
  bool _showPopup = false;
  Offset _popupPosition = Offset.zero;
  CelestialObject? _popupObject;
  final GlobalKey _skyViewKey = GlobalKey();

  // Slew mode state
  bool _slewMode = false;

  // FOV overlay state
  bool _showFOV = false;

  // Track if initial sync has been done
  bool _initialSyncDone = false;

  // Last `?ra=&dec=&name=` hand-off already applied, so re-running the parse on
  // an unrelated dependency change doesn't yank the view back to it after the
  // user has panned away.
  String? _appliedSkyTargetQuery;

  // Filter sidebar expansion state for the desktop layout.
  bool _filterSidebarExpanded = false;

  // Redesigned shell: which right-docked panel is open (desktop). Mutually
  // exclusive; on phone these surface as bottom sheets instead.
  bool _layersPanelOpen = false;
  bool _planPanelOpen = false;

  // Help overlay state
  bool _showHelpOverlay = false;

  bool _finderChartExportInFlight = false;

  // Gyroscope mount sync debounce timer
  Timer? _mountSyncDebounce;
  double? _lastSyncRA;
  double? _lastSyncDec;

  void _update(VoidCallback callback) => setState(callback);

  @override
  void initState() {
    super.initState();
    // Do initial sync after first frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _performInitialSync();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `GoRouterState.of` registers an inherited dependency, so this re-runs when
    // the location changes while the planetarium is already mounted (the Plan
    // Tonight IndexedStack keeps it built, so initState will not run again).
    _applySkyTargetQuery();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    _mountSyncDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final selectedObject = ref.watch(selectedObjectProvider);

    // Activate FOV-preset persistence: hydrate on first build, then write back
    // any preset edits to durable storage. Kept alive for the screen's lifetime.
    ref.watch(fovPresetsSyncProvider);

    // Activate the equipment→FOV binding so the "F" overlay reflects the rig
    // that is actually connected (active profile optics + connected camera
    // sensor + live rotator angle) without the user configuring anything. It
    // clears itself when the rig is unknown, so nothing bogus is drawn.
    ref.watch(equipmentFovBindingProvider);

    // Sync mount state from equipment provider to planetarium mount position provider
    ref.listen<MountState>(mountStateProvider, (previous, next) {
      final mountNotifier = ref.read(mountPositionProvider.notifier);
      if (next.connectionState == DeviceConnectionState.connected) {
        MountTrackingStatus status;
        if (next.isSlewing) {
          status = MountTrackingStatus.slewing;
        } else if (next.isParked) {
          status = MountTrackingStatus.parked;
        } else if (next.isTracking) {
          status = MountTrackingStatus.tracking;
        } else {
          status = MountTrackingStatus.stopped;
        }

        mountNotifier.updatePosition(
          raHours: next.ra,
          decDegrees: next.dec,
          status: status,
          isConnected: true,
        );
      } else {
        mountNotifier.setDisconnected();
      }
    });

    // Gyroscope sky aiming: update sky view center from device orientation,
    // and optionally send debounced slew commands to the remote mount.
    ref.listen<DeviceOrientationState>(deviceOrientationProvider,
        (previous, next) {
      if (!ref.read(gyroscopeAimingEnabledProvider)) return;
      if (!next.isActive) return;

      final location = ref.read(observerLocationProvider);
      final time = ref.read(observationTimeProvider);
      final result = deviceOrientationToRaDec(
        orientation: next,
        location: location,
        time: time,
      );
      if (result == null) return;

      final (raHours, decDeg) = result;

      // Always update local sky view immediately
      ref.read(skyViewStateProvider.notifier).setCenter(raHours, decDeg);

      // If mount sync is enabled, debounce slew commands (2s after user stops moving)
      if (ref.read(gyroscopeMountSyncProvider)) {
        _lastSyncRA = raHours;
        _lastSyncDec = decDeg;
        _mountSyncDebounce?.cancel();
        _mountSyncDebounce = Timer(const Duration(seconds: 2), () {
          if (!mounted) return;
          final ra = _lastSyncRA;
          final dec = _lastSyncDec;
          if (ra == null || dec == null) return;

          final mountService = ref.read(mountCommandServiceProvider);
          if (!mountService.isConnected) return;

          mountService.slewTo(ra, dec, showFeedback: false);
        });
      }
    });

    final nightVision = ref.watch(nightVisionModeProvider);

    // Time travel is a planetarium affordance and must not outlive the screen:
    // the observation clock is what the Dashboard's "Local" time, astro-dark
    // countdown and moon phase are evaluated against.
    return SimulatedTimeScope(
      child: _NightVisionFilter(
        enabled: nightVision,
        child: SkyHotkeyScope(
          onHotkey: _handleKeyEvent,
          child: GestureDetector(
            onTapDown: (details) {
              if (_showPopup) {
                final popupRect = resolveObjectInfoPopupLayout(
                  context,
                  _popupPosition,
                ).rect;
                if (!popupRect.contains(details.globalPosition)) {
                  _dismissPopup();
                }
              }
            },
            // Redesigned "top command bar + dockable panels" shell — ONE
            // adaptive layout for desktop and phone.
            child: _buildShell(context, colors, selectedObject),
          ),
        ),
      ),
    );
  }
}

/// Thin Scaffold wrapper kept for the redirected standalone `/planetarium`
/// route. The reusable body lives in [PlanetariumView], also hosted by Plan
/// Tonight's "Sky" tab.
class PlanetariumScreen extends StatelessWidget {
  const PlanetariumScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: SkotiqColors.of(context).background,
      body: const PlanetariumView(),
    );
  }
}
