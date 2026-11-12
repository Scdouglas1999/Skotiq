import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../../services/mount_command_service.dart';
import '../../../utils/authority_bound_dialog.dart';
import '../../../utils/cooled_camera_guard.dart';
import '../../../utils/device_format_utils.dart';
import '../../../utils/device_type_ui.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/focuser_backlash/effective_backlash_readout.dart';
import '../../../widgets/troubleshooter/connection_troubleshooter_dialog.dart';
import '../utils/device_error_subtitle.dart';
import '../utils/meridian_flip_pointer.dart';
import 'device_tile_width.dart';
import '../utils/profile_mutation_epoch.dart';
import '../utils/session_device_save.dart';
import '../../../utils/guide_distance.dart';

part 'connected_device_card/status_and_display.dart';
part 'connected_device_card/actions_and_telemetry.dart';
part 'connected_device_card/command_handlers.dart';
part 'connected_device_card/dialogs_and_settings.dart';
part 'connected_device_card/helper_widgets.dart';
part 'connected_device_card/motion_dialogs.dart';

/// Narrow adapters keep the equipment card on the canonical weather-safety
/// state machine while allowing the quick-action surface to be tested without
/// constructing its long-lived polling timers.
final equipmentSafetySnoozeStatusProvider = Provider<WeatherSafetyStatus>(
  (ref) => ref.watch(weatherSafetyProvider).status,
);

final equipmentSafetySnoozeActionProvider =
    Provider<void Function(Duration)>((ref) {
  return (duration) =>
      ref.read(weatherSafetyProvider.notifier).snooze(duration);
});

final equipmentSafetyCancelSnoozeActionProvider = Provider<VoidCallback>(
  (ref) => ref.read(weatherSafetyProvider.notifier).cancelSnooze,
);

/// Get display name for a device, preferring deviceName, falling back to formatted deviceId
String _getDeviceDisplayName(
    String? deviceName, String? deviceId, String fallback) {
  if (deviceName != null && deviceName.isNotEmpty) {
    return deviceName;
  }
  if (deviceId != null && deviceId.isNotEmpty) {
    return formatDeviceId(deviceId);
  }
  return fallback;
}

/// A card widget for displaying connected device status, metrics, and quick actions.
///
/// This widget provides a consistent interface for all device types with:
/// - Device icon and connection status badge
/// - Primary metrics specific to each device type
/// - Quick action buttons for common operations
/// - Expandable section for additional telemetry
class ConnectedDeviceCard extends ConsumerStatefulWidget {
  /// Must stay strictly shorter than `DeviceService.environmentPollInterval`.
  ///
  /// Sampling an age at exactly the period of the thing being aged yields the
  /// fixed phase offset between the two timers, not elapsed time. Both start
  /// from the same connect event, so at equal periods the offset is ~0 and
  /// "Last checked" prints "0s ago" indefinitely. 1 s ticks inside the poll
  /// window and is the granularity the label prints anyway.
  ///
  /// Exposed so the test asserts that relationship rather than the literal.
  @visibleForTesting
  static const freshnessTick = Duration(seconds: 1);

  final DeviceType type;
  final VoidCallback? onDisconnect;
  final VoidCallback? onSettings;

  /// True when this device is connected but is NOT the device the active profile
  /// assigns to its slot — an ad-hoc "Connect" from the Discovery panel that
  /// nothing persists, so it will not come back on the next launch.
  ///
  /// Passed in by the dashboard rather than watched here: the provider that
  /// answers it runs a periodic host poll on a remote backend, which a single
  /// card should not drag in and which leaves a pending timer in widget tests
  /// that mount a card on its own.
  final bool sessionOnly;

  /// A line under the device's name for what the card's device brings with
  /// it, e.g. the built-in guider's guide camera.
  final String? detail;

  const ConnectedDeviceCard({
    super.key,
    required this.type,
    this.onDisconnect,
    this.onSettings,
    this.sessionOnly = false,
    this.detail,
  });

  @override
  ConsumerState<ConnectedDeviceCard> createState() =>
      _ConnectedDeviceCardState();
}

class _ConnectedDeviceCardState extends ConsumerState<ConnectedDeviceCard>
    with SingleTickerProviderStateMixin {
  bool _isExpanded = false;
  bool _deviceCommandInFlight = false;
  bool _mountCommandInFlight = false;
  bool _domeCommandInFlight = false;
  bool _coverCalibratorCommandInFlight = false;
  int _commandRevision = 0;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  late AnimationController _expandController;
  late Animation<double> _expandAnimation;

  /// Clock behind the freshness ("… ago") labels. See [_startFreshnessTicker].
  Timer? _freshnessTimer;
  DateTime _freshnessNow = DateTime.now();

  static const _freshnessTick = ConnectedDeviceCard.freshnessTick;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        _commandRevision++;
        if (mounted &&
            (_deviceCommandInFlight ||
                _mountCommandInFlight ||
                _domeCommandInFlight ||
                _coverCalibratorCommandInFlight)) {
          setState(() {
            _deviceCommandInFlight = false;
            _mountCommandInFlight = false;
            _domeCommandInFlight = false;
            _coverCalibratorCommandInFlight = false;
          });
        }
      },
    );
    _expandController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _expandAnimation = CurvedAnimation(
      parent: _expandController,
      curve: Curves.easeOut,
    );
    _startFreshnessTicker();
  }

  /// Drive the "Last Checked / Last Updated" age labels from a clock.
  ///
  /// An age needs a ticking clock, not build time: computing
  /// `DateTime.now().difference(...)` during build only advances when the
  /// provider that SETS the timestamp emits — which is the moment the timestamp
  /// becomes `now` — so the label reads "0s ago" however stale the reading is.
  ///
  /// A local timer rather than the shared app ticker: `tickerProvider` is not
  /// auto-disposed, so a widget that watches it leaves its periodic timer
  /// running for the lifetime of the ProviderContainer. This one is owned by
  /// the card, cancelled in [dispose], and only started for the two device
  /// types that show a freshness label.
  void _startFreshnessTicker() {
    if (!_needsFreshnessClock) return;
    _freshnessTimer = Timer.periodic(_freshnessTick, (_) {
      if (mounted) setState(() => _freshnessNow = DateTime.now());
    });
  }

  bool get _needsFreshnessClock =>
      widget.type == DeviceType.safetyMonitor ||
      widget.type == DeviceType.weather;

  @override
  void dispose() {
    _freshnessTimer?.cancel();
    _backendSubscription?.close();
    _expandController.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _expandController.forward();
      } else {
        _expandController.reverse();
      }
    });
  }

  bool get _anyCommandInFlight =>
      _deviceCommandInFlight ||
      _mountCommandInFlight ||
      _domeCommandInFlight ||
      _coverCalibratorCommandInFlight;

  int? _beginDeviceCommand() {
    if (_anyCommandInFlight) return null;
    final revision = ++_commandRevision;
    setState(() => _deviceCommandInFlight = true);
    return revision;
  }

  int? _beginMountCommand() {
    if (_anyCommandInFlight) return null;
    final revision = ++_commandRevision;
    setState(() => _mountCommandInFlight = true);
    return revision;
  }

  int? _beginDomeCommand() {
    if (_anyCommandInFlight) return null;
    final revision = ++_commandRevision;
    setState(() => _domeCommandInFlight = true);
    return revision;
  }

  int? _beginCoverCalibratorCommand() {
    if (_anyCommandInFlight) return null;
    final revision = ++_commandRevision;
    setState(() => _coverCalibratorCommandInFlight = true);
    return revision;
  }

  void _finishDeviceCommand(int revision, SkotiqBackend backend) {
    if (!mounted ||
        revision != _commandRevision ||
        !identical(ref.read(backendProvider), backend)) {
      return;
    }
    setState(() => _deviceCommandInFlight = false);
  }

  void _finishMountCommand(int revision, SkotiqBackend backend) {
    if (!mounted ||
        revision != _commandRevision ||
        !identical(ref.read(backendProvider), backend)) {
      return;
    }
    setState(() => _mountCommandInFlight = false);
  }

  void _finishDomeCommand(int revision, SkotiqBackend backend) {
    if (!mounted ||
        revision != _commandRevision ||
        !identical(ref.read(backendProvider), backend)) {
      return;
    }
    setState(() => _domeCommandInFlight = false);
  }

  void _finishCoverCalibratorCommand(
    int revision,
    SkotiqBackend backend,
  ) {
    if (!mounted ||
        revision != _commandRevision ||
        !identical(ref.read(backendProvider), backend)) {
      return;
    }
    setState(() => _coverCalibratorCommandInFlight = false);
  }

  /// Writes this device into the active profile so it comes back on the next
  /// launch — the remedy the "Connected but not in this profile" line offers.
  Future<void> _addToProfile() async {
    final profile = ref.read(activeEquipmentProfileProvider);
    final profileId = profile?.id;
    final slot = widget.type;
    if (profileId == null) return;
    try {
      await saveSessionDevicesToProfile(
        ref,
        profileId: profileId,
        slots: <DeviceType>{slot},
      );
      if (!mounted) return;
      ref.read(profileMutationEpochProvider.notifier).state++;
      context.showSuccessSnackBar('Added to "${profile!.name}".');
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Could not add to the profile: ${userFacingError(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final connectionState = _getConnectionState();
    final accentColor = widget.type.accentColor(colors);
    final live = connectionState == DeviceConnectionState.connected;

    // A panel, not a bordered card: the connection state is carried by the
    // status chip in the header, so the container needs no coloured ring
    // (06 §Equipment removes the green device-card borders).
    return SkotiqPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(colors, accentColor, connectionState),

          const SizedBox(height: SkotiqTokens.spaceMd),

          // Readings and controls belong to a device that is up. One that is
          // still connecting, or dropped, shows why and what can be done.
          if (live) _buildMetricsRow(colors),

          _buildErrorSubtitle(colors, connectionState),

          _buildSessionOnlyNotice(colors, connectionState),

          const SizedBox(height: SkotiqTokens.spaceMd),

          if (live)
            _buildActionsRow(colors)
          else if (connectionState == DeviceConnectionState.error)
            _buildFailedActionsRow(),

          if (live)
            SizeTransition(
              sizeFactor: _expandAnimation,
              child: _buildExpandedContent(colors),
            ),
        ],
      ),
    );
  }
}
