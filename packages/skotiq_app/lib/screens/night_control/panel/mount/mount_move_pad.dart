// The Mount tab's move pad: hold an arrow to move an axis, release to stop.
//
// The hold logic came from the dashboard's mount card. A MoveAxis that never
// receives its matching stop drives the mount into the pier, so three things
// end every move: the pointer coming up, the [kMountJogMaxHold] watchdog, and
// the pad leaving the tree. A keyboard or screen-reader activation cannot
// hold, so it sends one bounded nudge (start, then stop) instead.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../../../services/mount_command_service.dart';
import '../../../../utils/snackbar_helper.dart';
import 'mount_jog.dart';
import 'night_panel_parts.dart';

/// Identity for the pad's Stop all motion button.
const ValueKey<String> mountJogStopKey = ValueKey<String>('mountJog.stop');

/// How long a keyboard or screen-reader nudge holds the axis.
const Duration kMountJogNudge = Duration(milliseconds: 400);

/// Edge of one pad button.
const double _cell = 40;

/// The N / E / STOP / W / S pad and its rate selector.
class NightMountMovePad extends ConsumerStatefulWidget {
  const NightMountMovePad({
    super.key,
    required this.isEnabled,
    required this.deviceId,
    required this.capabilities,
    required this.capabilitiesLoading,
    this.disabledReason,
  });

  /// False when the mount cannot be moved by hand right now (parked, a run
  /// owns it, no host); [disabledReason] says why.
  final bool isEnabled;

  /// Why the pad is inert, or null when the reason is one the pad works out
  /// itself from [capabilities].
  final String? disabledReason;
  final String? deviceId;
  final MountCapabilities? capabilities;
  final bool capabilitiesLoading;

  @override
  ConsumerState<NightMountMovePad> createState() => _NightMountMovePadState();
}

class _NightMountMovePadState extends ConsumerState<NightMountMovePad> {
  /// The direction currently held down, or null when the pad is at rest.
  String? _held;

  /// Guards against a held axis outliving the press (see [kMountJogMaxHold]).
  Timer? _holdWatchdog;

  /// The backend the in-flight MoveAxis was sent to. Captured at start because
  /// `ref` is already unusable inside `dispose`, and the axis must still be
  /// stopped when the pad is torn down mid-press.
  DeviceBackend? _jogBackend;

  MountJogRate? _rate;

  /// The arrow showing a keyboard focus ring.
  String? _focused;

  final Map<String, FocusNode> _focusNodes = <String, FocusNode>{};

  FocusNode _focusNode(String direction) => _focusNodes.putIfAbsent(
        direction,
        () => FocusNode(debugLabel: 'mountJog.$direction'),
      );

  @override
  void dispose() {
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    _holdWatchdog?.cancel();
    // Never leave an axis running because the pad was rebuilt away. Fire and
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

  bool get _padEnabled =>
      widget.isEnabled &&
      widget.deviceId != null &&
      _mode != MountJogMode.unavailable;

  /// The reason the pad is inert, or null when it is live. A caller-supplied
  /// reason (parked) wins over the capability-derived one: it is the one the
  /// operator can act on.
  String? _inertReason(SkotiqLocalizations l10n) {
    if (!widget.isEnabled) {
      return widget.disabledReason ?? l10n.text('nightScopeJogUnavailable');
    }
    if (widget.deviceId == null) return l10n.text('nightActWhyNoMount');
    if (_mode == MountJogMode.unavailable) {
      return widget.capabilitiesLoading
          ? l10n.text('nightScopeJogReadingCaps')
          : l10n.text('nightScopeJogNoMoves');
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = context.skotiqColors;
    final enabled = _padEnabled;
    final inert = _inertReason(l10n);

    Widget arrow(String direction, String letter, String nameKey) => _jogButton(
          direction: direction,
          letter: letter,
          name: l10n.text(nameKey),
          enabled: enabled,
          inertReason: inert,
        );

    final pad = SizedBox(
      width: _cell * 3 + kNightPanelCellGap * 2,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [arrow('north', 'N', 'nightScopeNorth')],
          ),
          const SizedBox(height: kNightPanelCellGap),
          // East on the left, as the sky looks facing the meridian.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              arrow('east', 'E', 'nightScopeEast'),
              _stopButton(l10n, colors),
              arrow('west', 'W', 'nightScopeWest'),
            ],
          ),
          const SizedBox(height: kNightPanelCellGap),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [arrow('south', 'S', 'nightScopeSouth')],
          ),
        ],
      ),
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Dim the whole pad when it is inert: a dimmed letter alone is not
        // readable as "disabled" on the dark theme.
        if (enabled)
          pad
        else
          Opacity(key: mountJogDisabledVeilKey, opacity: 0.45, child: pad),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(child: _rateColumn(l10n, colors, inert)),
      ],
    );
  }

  /// Beside the pad: the reason it is inert, the rate selector when it really
  /// moves an axis, or what the arrows do instead.
  Widget _rateColumn(
    SkotiqLocalizations l10n,
    SkotiqColors colors,
    String? inert,
  ) {
    if (inert != null) return NightPanelNote(inert);
    if (_mode == MountJogMode.pulse) {
      return NightPanelNote(
        l10n.text(
          'nightScopeJogPulses',
          params: {'ms': '$kMountJogPulseMs'},
        ),
      );
    }
    final selected = _selectedRate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.text('nightScopeJogRate'),
          style:
              SkotiqTypography.readoutLabel.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: kNightPanelRowGap),
        NightPanelButtonGrid(
          columns: 2,
          buttons: [
            for (final rate in _rates)
              NightPanelButtonSpec(
                key: ValueKey<String>('mountJog.rate.${rate.label}'),
                label: rate.label,
                selected: rate == selected,
                tooltip: '${rate.degPerSec.toStringAsFixed(3)}°/s',
                onPressed: () => setState(() => _rate = rate),
              ),
          ],
        ),
      ],
    );
  }

  Widget _stopButton(SkotiqLocalizations l10n, SkotiqColors colors) {
    final canStop = widget.deviceId != null;
    return Tooltip(
      message: l10n.text('nightScopeStopAll'),
      child: Semantics(
        button: true,
        enabled: canStop,
        label: l10n.text('nightScopeStopAll'),
        excludeSemantics: true,
        child: SizedBox(
          width: _cell,
          height: _cell,
          child: Material(
            key: mountJogStopKey,
            color: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
              side: BorderSide(color: colors.error.withValues(alpha: 0.6)),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
              onTap: canStop ? () => unawaited(_stopAll()) : null,
              child: Center(
                child: Text(
                  l10n.text('nightScopeStop'),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: SkotiqTypography.labelStrongSm.copyWith(
                    color: canStop ? colors.error : colors.textMuted,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _jogButton({
    required String direction,
    required String letter,
    required String name,
    required bool enabled,
    required String? inertReason,
  }) {
    final l10n = context.l10n;
    final colors = context.skotiqColors;
    final isActive = _held == direction;
    final isFocused = _focused == direction;
    return Tooltip(
      key: mountJogButtonKey(direction),
      // The tooltip carries the reason when the pad is inert: "Hold to move
      // East" over an arrow that cannot move would be false.
      message: inertReason ??
          switch (_mode) {
            MountJogMode.slew => l10n.text(
                'nightScopeJogHoldSlew',
                params: {'direction': name, 'rate': _selectedRate.label},
              ),
            MountJogMode.pulse => l10n.text(
                'nightScopeJogHoldPulse',
                params: {'direction': name},
              ),
            MountJogMode.unavailable => l10n.text('nightScopeJogNoMoves'),
          },
      child: Semantics(
        button: true,
        enabled: enabled,
        label: name,
        // Assistive tech cannot express hold-and-release, so a semantics tap
        // performs the same bounded nudge as the keyboard. When the pad is
        // inert the tap still lands, and gets told why.
        onTap: enabled ? () => unawaited(_nudge(direction)) : _explainInert,
        excludeSemantics: true,
        child: FocusableActionDetector(
          focusNode: _focusNode(direction),
          onShowFocusHighlight: (show) => setState(() {
            if (show) {
              _focused = direction;
            } else if (_focused == direction) {
              _focused = null;
            }
          }),
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                if (enabled) {
                  unawaited(_nudge(direction));
                } else {
                  _explainInert();
                }
                return null;
              },
            ),
          },
          child: Listener(
            onPointerDown: enabled
                ? (_) => unawaited(_startJog(direction))
                : (_) => _explainInert(),
            onPointerUp: enabled ? (_) => unawaited(_stopJog()) : null,
            onPointerCancel: enabled ? (_) => unawaited(_stopJog()) : null,
            child: Container(
              width: _cell,
              height: _cell,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isActive
                    ? colors.primary.withValues(alpha: 0.3)
                    : colors.surfaceElevated,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
                border: isFocused
                    ? Border.all(color: colors.primary, width: 2)
                    : null,
              ),
              child: Text(
                letter,
                style: SkotiqTypography.labelStrong.copyWith(
                  color: enabled ? colors.textPrimary : colors.textMuted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Answer a press on an inert arrow instead of swallowing it.
  void _explainInert() {
    if (!mounted) return;
    final reason = _inertReason(context.l10n);
    if (reason == null) return;
    context.showWarningSnackBar(reason);
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
          context.l10n.text(
            'nightScopeJogWatchdog',
            params: {'seconds': '${kMountJogMaxHold.inSeconds}'},
          ),
        );
      }
    });

    switch (_mode) {
      case MountJogMode.slew:
        final move = mountJogAxis(direction, _selectedRate.degPerSec);
        // Hold the backend that received the start. `ref` is unusable by the
        // time dispose() runs, and the stop belongs to the same authority the
        // start went to, not to whatever the app has switched to since.
        final backend = ref.read(deviceBackendProvider);
        _jogBackend = backend;
        try {
          await backend.mountMoveAxis(deviceId, move.axis, move.rate);
        } catch (error) {
          if (mounted) {
            context.showErrorSnackBar(
              context.l10n
                  .text('nightScopeJogFailed', params: {'error': '$error'}),
            );
          }
          // The driver may still have started the axis before throwing.
          await _stopJog();
        }
      case MountJogMode.pulse:
        // Not awaited: the loop runs until the button is released, and
        // awaiting it here would leave the nudge unable to issue its release.
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
      if (mounted) {
        context.showErrorSnackBar(
          context.l10n
              .text('nightScopeJogStopFailed', params: {'error': '$error'}),
        );
      }
    }
  }

  /// Stop all motion: release a held arrow, then abort any slew.
  Future<void> _stopAll() async {
    await _stopJog();
    final result = await ref
        .read(mountCommandServiceProvider)
        .abortSlew(showFeedback: false);
    if (mounted && !result.isSuccess) context.showCommandActionResult(result);
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
      // Pace the next pulse behind the one just issued so the loop cannot
      // spin.
      await Future<void>.delayed(
        const Duration(milliseconds: kMountJogPulseMs),
      );
    }
  }

  /// A bounded press-and-release, for the keyboard and the semantics tap.
  Future<void> _nudge(String direction) async {
    await _startJog(direction);
    await Future<void>.delayed(kMountJogNudge);
    await _stopJog();
  }
}
