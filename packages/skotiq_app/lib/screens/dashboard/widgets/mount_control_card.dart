import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../services/mount_command_service.dart';
import '../../../utils/snackbar_helper.dart';
import '../../accessible_dropdown.dart';
import 'glass_card.dart';
import 'mount_jog.dart';

class MountControlCard extends ConsumerWidget {
  final SkotiqColors colors;

  const MountControlCard({super.key, required this.colors});

  static const double _expandedThreshold = 280.0;

  // Dec keeps a bespoke formatter because this card renders it without spaces
  // between the components (±DD°MM'SS"), which no shared SexagesimalStyle emits.
  String _formatDec(double dec) => CoordinateFormat.dec(
        dec,
        style: SexagesimalStyle.compactLetters,
        seconds: SecondsPrecision.integerRounded,
      );

  String _trackingRateLabel(TrackingRate rate) {
    return switch (rate) {
      TrackingRate.sidereal => 'Sidereal',
      TrackingRate.lunar => 'Lunar',
      TrackingRate.solar => 'Solar',
      TrackingRate.king => 'King',
      TrackingRate.custom => 'Custom',
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final mountState = ref.watch(mountStateProvider);
    final isConnected =
        mountState.connectionState == DeviceConnectionState.connected;
    // Unknown capabilities must not manufacture supported rates. Retain only
    // the current value so the dropdown remains valid while failing closed.
    final mountCapabilitiesAsync =
        ref.watch(mountCapabilitiesProvider(mountState.deviceId ?? ''));
    final mountCapabilities = mountCapabilitiesAsync.valueOrNull;
    final supportedRates =
        mountCapabilities?.supportedTrackingRates ?? const <TrackingRate>[];
    final trackingRateOptions = supportedRates.toList();
    if (!trackingRateOptions.contains(mountState.trackingRate)) {
      trackingRateOptions.insert(0, mountState.trackingRate);
    }
    final canSetTrackingRate = isConnected &&
        mountCapabilities?.canSetTrackingRate == true &&
        supportedRates.isNotEmpty;

    final raText = mountState.ra != null
        ? CoordinateFormat.ra(mountState.ra!,
            style: SexagesimalStyle.paddedColons,
            seconds: SecondsPrecision.integerRounded)
        : kReadoutUnknown;
    final decText =
        mountState.dec != null ? _formatDec(mountState.dec!) : kReadoutUnknown;
    final pierText = isConnected
        ? (mountState.sideOfPier?.toUpperCase() ?? kReadoutUnknown)
        : kReadoutUnknown;

    // Status with color
    final (statusText, statusColor) = mountState.isSlewing
        ? (l10n.text('slewing'), colors.warning)
        : mountState.isParked
            ? (l10n.text('parked'), colors.textMuted)
            : mountState.isTracking
                ? (l10n.text('tracking'), colors.success)
                : isConnected
                    ? (l10n.text('idle'), colors.textSecondary)
                    : (l10n.text('off'), colors.textMuted);

    return DashboardGlassCard(
      colors: colors,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isExpanded = constraints.maxWidth >= _expandedThreshold;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              DashboardCardHeader(
                colors: colors,
                icon: LucideIcons.move3d,
                title: l10n.text('mount'),
                accent: mountState.isTracking ? colors.success : colors.info,
                trailing: DashboardStatusChip(
                  colors: colors,
                  label: statusText,
                  active: true,
                  activeColor: statusColor,
                ),
              ),

              const SizedBox(height: DashboardCardStyle.headerGap),

              // Coordinates - NINA style
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colors.surfaceAlt.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l10n.text('ra'),
                              style: SkotiqTypography.caption
                                  .copyWith(color: colors.textMuted)),
                          Text(raText,
                              style: SkotiqTypography.readoutXs
                                  .copyWith(color: colors.textPrimary)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l10n.text('dec'),
                              style: SkotiqTypography.caption
                                  .copyWith(color: colors.textMuted)),
                          Text(decText,
                              style: SkotiqTypography.readoutXs
                                  .copyWith(color: colors.textPrimary)),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(l10n.text('pier'),
                            style: SkotiqTypography.caption
                                .copyWith(color: colors.textMuted)),
                        Text(pierText,
                            style: SkotiqTypography.h6
                                .copyWith(color: colors.textPrimary)),
                      ],
                    ),
                  ],
                ),
              ),

              // Expanded mode: Directional controls and tracking rate
              if (isExpanded && isConnected) ...[
                const SizedBox(height: 10),

                // Hold-to-jog controls (N/S/E/W) plus their speed selector.
                MountJogControls(
                  colors: colors,
                  isEnabled: isConnected && !mountState.isParked,
                  // A parked mount refuses every move command, so the pad must
                  // say why instead of accepting presses that go nowhere.
                  disabledReason: mountState.isParked
                      ? 'Mount is parked — unpark first.'
                      : null,
                  deviceId: mountState.deviceId,
                  capabilities: mountCapabilities,
                  capabilitiesLoading: mountCapabilitiesAsync.isLoading,
                ),

                const SizedBox(height: 10),

                // Tracking rate selector
                Row(
                  children: [
                    Text('${l10n.text('rate')}:',
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.textMuted)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Container(
                        height: 28,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: colors.surfaceAlt,
                          borderRadius:
                              BorderRadius.circular(SkotiqTokens.radiusInline4),
                          border: Border.all(
                              color: colors.border.withValues(alpha: 0.5)),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: AccessibleDropdown<TrackingRate>(
                            value: mountState.trackingRate,
                            isDense: true,
                            isExpanded: true,
                            style: SkotiqTypography.caption
                                .copyWith(color: colors.textPrimary),
                            dropdownColor: colors.surface,
                            icon: Icon(LucideIcons.chevronDown,
                                size: 12, color: colors.textMuted),
                            items: trackingRateOptions
                                .map((rate) => DropdownMenuItem(
                                      value: rate,
                                      child: Text(_trackingRateLabel(rate)),
                                    ))
                                .toList(),
                            onChanged: canSetTrackingRate
                                ? (rate) async {
                                    if (rate == null) return;
                                    final r = await ref
                                        .read(mountCommandServiceProvider)
                                        .setTrackingRate(rate);
                                    if (context.mounted) {
                                      context.showCommandActionResult(r);
                                    }
                                  }
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],

              const SizedBox(height: 8),

              // Buttons
              Row(
                children: [
                  Expanded(
                    child: SkotiqButton(
                      label: mountState.isParked
                          ? l10n.text('unpark')
                          : l10n.text('park'),
                      icon: LucideIcons.parkingCircle,
                      variant: ButtonVariant.outline,
                      size: ButtonSize.small,
                      onPressed: isConnected
                          ? () async {
                              final r = await ref
                                  .read(mountCommandServiceProvider)
                                  .togglePark();
                              if (context.mounted) {
                                context.showCommandActionResult(r);
                              }
                            }
                          : null,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SkotiqButton(
                      label: mountState.isTracking
                          ? l10n.text('stop')
                          : l10n.text('track'),
                      icon: LucideIcons.activity,
                      variant: mountState.isTracking
                          ? ButtonVariant.primary
                          : ButtonVariant.outline,
                      size: ButtonSize.small,
                      onPressed: isConnected
                          ? () async {
                              final r = await ref
                                  .read(mountCommandServiceProvider)
                                  .toggleTracking();
                              if (context.mounted) {
                                context.showCommandActionResult(r);
                              }
                            }
                          : null,
                    ),
                  ),
                ],
              ),
              if (mountState.isSlewing) ...[
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: SkotiqButton(
                    label: l10n.text('abortSlew'),
                    icon: LucideIcons.xCircle,
                    variant: ButtonVariant.outline,
                    size: ButtonSize.small,
                    onPressed: isConnected
                        ? () async {
                            final r = await ref
                                .read(mountCommandServiceProvider)
                                .abortSlew();
                            if (context.mounted) {
                              context.showCommandActionResult(r);
                            }
                          }
                        : null,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Hold-to-jog pad (N/S/E/W) plus its speed selector.
///
/// An arrow pad on a mount card has to slew while held and stop on release,
/// which is what [MountJogMode.slew] does through MoveAxis.
/// Mounts whose driver has no MoveAxis fall back to REPEATED guide pulses and
/// the pad says so, so the operator can read what the arrows actually do.
@visibleForTesting
class MountJogControls extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final bool isEnabled;

  /// Why the pad cannot move the mount right now (e.g. it is parked), or null
  /// when the reason is one the pad works out itself from [capabilities].
  ///
  /// Shown under the pad, in every arrow's tooltip, and as a snackbar when an
  /// arrow is pressed anyway — an inert pad that stays silent is the defect.
  final String? disabledReason;
  final String? deviceId;
  final MountCapabilities? capabilities;
  final bool capabilitiesLoading;

  const MountJogControls({
    super.key,
    required this.colors,
    required this.isEnabled,
    required this.deviceId,
    required this.capabilities,
    required this.capabilitiesLoading,
    this.disabledReason,
  });

  @override
  ConsumerState<MountJogControls> createState() => _MountJogControlsState();
}

class _MountJogControlsState extends ConsumerState<MountJogControls> {
  /// The direction currently held down, or null when the pad is at rest.
  String? _held;

  /// Guards against a held axis outliving the press (see [kMountJogMaxHold]).
  Timer? _holdWatchdog;

  /// The backend the in-flight MoveAxis was sent to. Captured at start because
  /// `ref` is already unusable inside `dispose`, and the axis MUST still be
  /// stopped when the pad is torn down mid-press.
  DeviceBackend? _jogBackend;

  MountJogRate? _rate;

  @override
  void dispose() {
    _holdWatchdog?.cancel();
    // Never leave an axis running because the card was rebuilt away. Fire and
    // forget: dispose cannot await, but the stop must still be issued.
    final held = _held;
    _held = null;
    if (held != null && widget.deviceId != null) {
      unawaited(_sendStop(widget.deviceId!, held));
    }
    super.dispose();
  }

  MountJogMode get _mode => mountJogModeFor(widget.capabilities);

  List<MountJogRate> get _rates =>
      mountJogRates(widget.capabilities?.maxSlewRate);

  MountJogRate get _selectedRate {
    final rates = _rates;
    final current = _rate;
    if (current != null && rates.contains(current)) return current;
    return defaultMountJogRate(rates);
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final mode = _mode;
    final padEnabled = widget.isEnabled &&
        widget.deviceId != null &&
        mode != MountJogMode.unavailable;

    final pad = Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colors.surfaceAlt.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _jogButton(LucideIcons.chevronLeft, 'W', 'west', padEnabled),
          const SizedBox(width: 2),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _jogButton(LucideIcons.chevronUp, 'N', 'north', padEnabled),
              const SizedBox(height: 2),
              _jogButton(LucideIcons.chevronDown, 'S', 'south', padEnabled),
            ],
          ),
          const SizedBox(width: 2),
          _jogButton(LucideIcons.chevronRight, 'E', 'east', padEnabled),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Dim the WHOLE pad when it is inert. The icon colour alone (textPrimary
        // -> textMuted) is not readable as "disabled" on the dark theme.
        if (padEnabled)
          pad
        else
          Opacity(
            key: mountJogDisabledVeilKey,
            opacity: 0.45,
            child: pad,
          ),
        const SizedBox(height: 6),
        _modeRow(mode),
      ],
    );
  }

  /// The reason the pad is inert, or null when it is live. A caller-supplied
  /// reason (parked) wins over the capability-derived one: it is the one the
  /// operator can act on.
  String? get _inertReason {
    if (!widget.isEnabled) {
      return widget.disabledReason ?? 'Mount controls are unavailable.';
    }
    if (widget.deviceId == null) return 'No mount is connected.';
    if (_mode == MountJogMode.unavailable) {
      return widget.capabilitiesLoading
          ? 'Reading mount capabilities…'
          : 'This mount reports neither axis slewing nor guide pulses, so the '
              'arrows are unavailable.';
    }
    return null;
  }

  /// Answer a press on an inert arrow instead of swallowing it.
  void _explainInert() {
    final reason = _inertReason;
    if (reason == null || !mounted) return;
    context.showWarningSnackBar(reason);
  }

  /// The row under the pad: the reason the arrows are inert when they are, a
  /// speed selector when the pad really slews, and otherwise a plain statement
  /// of what the arrows do instead.
  Widget _modeRow(MountJogMode mode) {
    final colors = widget.colors;
    final labelStyle =
        SkotiqTypography.caption.copyWith(color: colors.textMuted);

    final inert = _inertReason;
    if (inert != null) {
      return Text(inert, style: labelStyle);
    }

    if (mode == MountJogMode.slew) {
      final rates = _rates;
      return Row(
        children: [
          Text('Jog:', style: labelStyle),
          const SizedBox(width: 6),
          Expanded(
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: colors.surfaceAlt,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
                border: Border.all(color: colors.border.withValues(alpha: 0.5)),
              ),
              child: DropdownButtonHideUnderline(
                child: AccessibleDropdown<MountJogRate>(
                  value: _selectedRate,
                  isDense: true,
                  isExpanded: true,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textPrimary),
                  dropdownColor: colors.surface,
                  icon: Icon(LucideIcons.chevronDown,
                      size: 12, color: colors.textMuted),
                  items: rates
                      .map((rate) => DropdownMenuItem(
                            value: rate,
                            child: Text(
                              '${rate.label}  '
                              '(${rate.degPerSec.toStringAsFixed(3)}°/s)',
                            ),
                          ))
                      .toList(),
                  onChanged: (rate) {
                    if (rate == null) return;
                    setState(() => _rate = rate);
                  },
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Text(
      'Guide pulses ($kMountJogPulseMs ms while held) — this mount reports '
      'no axis slewing.',
      style: labelStyle,
    );
  }

  Widget _jogButton(
    IconData icon,
    String label,
    String direction,
    bool isEnabled,
  ) {
    final colors = widget.colors;
    final isActive = _held == direction;
    final inert = _inertReason;
    return Tooltip(
      key: mountJogButtonKey(direction),
      // The tooltip carries the REASON when the pad is inert: "Hold to slew E"
      // over an arrow that cannot move would be false.
      message: inert ??
          switch (_mode) {
            MountJogMode.slew =>
              'Hold to slew $label at ${_selectedRate.label}',
            MountJogMode.pulse => 'Hold to guide-pulse $label',
            MountJogMode.unavailable => 'Jog unavailable on this mount',
          },
      child: Semantics(
        button: true,
        enabled: isEnabled,
        label: 'Jog $label',
        // Assistive tech cannot express hold-and-release, so a semantics tap
        // performs the same bounded nudge a quick press does. When the pad is
        // inert the tap still lands — and gets told why.
        onTap: isEnabled ? () => unawaited(_nudge(direction)) : _explainInert,
        child: Listener(
          onPointerDown: isEnabled
              ? (_) => unawaited(_startJog(direction))
              : (_) => _explainInert(),
          onPointerUp: isEnabled ? (_) => unawaited(_stopJog()) : null,
          onPointerCancel: isEnabled ? (_) => unawaited(_stopJog()) : null,
          child: Material(
            color: isActive
                ? colors.primary.withValues(alpha: 0.3)
                : colors.surfaceAlt,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
            child: SizedBox(
              width: 32,
              height: 32,
              child: Icon(
                icon,
                size: 16,
                color: isEnabled ? colors.textPrimary : colors.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Start moving and keep moving until [_stopJog].
  Future<void> _startJog(String direction) async {
    final deviceId = widget.deviceId;
    if (deviceId == null || _held != null) return;
    setState(() => _held = direction);
    _holdWatchdog?.cancel();
    _holdWatchdog = Timer(kMountJogMaxHold, () {
      unawaited(_stopJog());
      if (mounted) {
        context.showWarningSnackBar(
          'Jog stopped after ${kMountJogMaxHold.inSeconds}s.',
        );
      }
    });

    switch (_mode) {
      case MountJogMode.slew:
        final move = mountJogAxis(direction, _selectedRate.degPerSec);
        // Hold the backend that received the START. `ref` is already unusable
        // by the time dispose() runs, and in any case the stop belongs to the
        // same authority the start went to — not to whatever the app has
        // switched to since.
        final backend = ref.read(deviceBackendProvider);
        _jogBackend = backend;
        try {
          await backend.mountMoveAxis(deviceId, move.axis, move.rate);
        } catch (error) {
          if (mounted) context.showErrorSnackBar('Jog failed: $error');
          // The driver may still have started the axis before throwing.
          await _stopJog();
        }
      case MountJogMode.pulse:
        // NOT awaited: the loop runs until the button is released, and awaiting
        // it here would leave the caller (the semantics nudge) unable to issue
        // its own release.
        unawaited(_pulseWhileHeld(direction));
      case MountJogMode.unavailable:
        await _stopJog();
    }
  }

  /// Stop whatever the pad started. Safe to call when nothing is held.
  Future<void> _stopJog() async {
    final direction = _held;
    _holdWatchdog?.cancel();
    _holdWatchdog = null;
    if (direction == null) return;
    if (mounted) {
      setState(() => _held = null);
    } else {
      _held = null;
    }

    final deviceId = widget.deviceId;
    if (deviceId == null) return;
    await _sendStop(deviceId, direction);
  }

  /// The stop half of a MoveAxis pair. A pulse jog needs none: each pulse is
  /// self-limiting, and the loop simply stops issuing more.
  Future<void> _sendStop(String deviceId, String direction) async {
    final backend = _jogBackend;
    if (backend == null) return;
    _jogBackend = null;
    final axis = mountJogAxis(direction, 1.0).axis;
    try {
      await backend.mountMoveAxis(deviceId, axis, 0.0);
    } catch (error) {
      if (mounted) context.showErrorSnackBar('Jog stop failed: $error');
    }
  }

  /// Repeat guide pulses for as long as the button is held. This is the whole
  /// fallback for a mount with no MoveAxis: one pulse per press was invisible.
  Future<void> _pulseWhileHeld(String direction) async {
    final service = ref.read(mountCommandServiceProvider);
    while (mounted && _held == direction) {
      final result =
          await service.pulseGuide(direction, durationMs: kMountJogPulseMs);
      if (!result.isSuccess) {
        if (mounted) context.showCommandActionResult(result);
        await _stopJog();
        return;
      }
      // Pace the next pulse behind the one just issued so the loop cannot spin.
      await Future<void>.delayed(
        const Duration(milliseconds: kMountJogPulseMs),
      );
    }
  }

  /// A bounded press-and-release, for the semantics tap action.
  Future<void> _nudge(String direction) async {
    await _startJog(direction);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await _stopJog();
  }
}
