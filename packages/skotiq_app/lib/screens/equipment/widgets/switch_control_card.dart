import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';

/// Per-channel control for a connected multi-channel Switch / power box (dew
/// heaters, outlets, etc.).
///
/// Switches are not a [ConnectedDeviceType], so they get no standard device
/// card; the Equipment screen renders this card directly when a switch is
/// connected. Reads/writes go through [DeviceService] → SwitchChannelService,
/// which now works over the network as well as locally (the remote-switch fix),
/// so a tablet operator can toggle the rig's dew heaters / power outlets.
class SwitchControlCard extends ConsumerStatefulWidget {
  const SwitchControlCard({super.key});

  @override
  ConsumerState<SwitchControlCard> createState() => _SwitchControlCardState();
}

class _SwitchControlCardState extends ConsumerState<SwitchControlCard> {
  final _pending = <int>{};
  final _analogDrafts = <int, double>{};
  bool _refreshing = false;
  ProviderSubscription<DeviceService>? _serviceSubscription;

  @override
  void initState() {
    super.initState();
    _serviceSubscription = ref.listenManual<DeviceService>(
      deviceServiceProvider,
      (previous, next) {
        if (previous == null || identical(previous, next)) return;
        if (mounted) {
          setState(() {
            _refreshing = false;
            _pending.clear();
            _analogDrafts.clear();
          });
        }
      },
    );
    // Connect already refreshes channels, but a client that opens the screen
    // after the switch connected needs a pull to populate names/states.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _serviceSubscription?.close();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    final service = ref.read(deviceServiceProvider);
    setState(() => _refreshing = true);
    try {
      await service.refreshSwitchChannels();
    } catch (e) {
      if (mounted && _isCurrentService(service)) {
        context.showErrorSnackBar('Channel refresh failed: $e');
      }
    } finally {
      if (_isCurrentService(service)) {
        setState(() => _refreshing = false);
      }
    }
  }

  Future<void> _toggle(int index, bool value) async {
    if (_pending.contains(index)) return;
    final service = ref.read(deviceServiceProvider);
    setState(() => _pending.add(index));
    try {
      await service.setSwitchChannel(index, value);
    } catch (e) {
      if (mounted && _isCurrentService(service)) {
        context.showErrorSnackBar('Switch failed: $e');
      }
    } finally {
      if (_isCurrentService(service)) {
        setState(() => _pending.remove(index));
      }
    }
  }

  Future<void> _setValue(int index, double value) async {
    if (_pending.contains(index)) return;
    final service = ref.read(deviceServiceProvider);
    setState(() => _pending.add(index));
    try {
      await service.setSwitchChannelValue(index, value);
    } catch (e) {
      if (mounted && _isCurrentService(service)) {
        context.showErrorSnackBar('Switch failed: $e');
      }
    } finally {
      if (_isCurrentService(service)) {
        setState(() {
          _pending.remove(index);
          _analogDrafts.remove(index);
        });
      }
    }
  }

  bool _isCurrentService(DeviceService service) =>
      mounted && identical(ref.read(deviceServiceProvider), service);

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final state = ref.watch(switchStateProvider);
    if (state.connectionState != DeviceConnectionState.connected) {
      return const SizedBox.shrink();
    }
    final count = state.channelCount;
    final names = state.channelNames;
    final states = state.channelStates;

    return SkotiqPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: _switchIconSquare,
                height: _switchIconSquare,
                decoration: SkotiqDecorations.well(colors),
                child: Icon(
                  LucideIcons.power,
                  size: SkotiqTokens.iconSm,
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm + 2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Switch'.toUpperCase(),
                      style: SkotiqTypography.eyebrow.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                    Text(
                      state.deviceName ?? 'Switch',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SkotiqTypography.bodyStrong.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              SkotiqIconButton(
                icon: LucideIcons.refreshCw,
                tooltip: 'Refresh channels',
                size: IconButtonSize.sm,
                onPressed: _refreshing ? null : _refresh,
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          if (count == 0)
            Text('No channels reported',
                style: SkotiqTypography.bodySm
                    .copyWith(color: colors.textMuted))
          else
            for (var i = 0; i < count; i++)
              _buildChannel(
                index: i,
                state: state,
                names: names,
                states: states,
                colors: colors,
              ),
        ],
      ),
    );
  }

  Widget _buildChannel({
    required int index,
    required SwitchState state,
    required List<String> names,
    required List<bool> states,
    required SkotiqColors colors,
  }) {
    final name = index < names.length && names[index].isNotEmpty
        ? names[index]
        : 'Channel ${index + 1}';
    final description = index < state.channelDescriptions.length
        ? state.channelDescriptions[index]
        : '';
    final isBoolean =
        index >= state.channelIsBoolean.length || state.channelIsBoolean[index];
    final canWrite =
        index >= state.channelCanWrite.length || state.channelCanWrite[index];
    final pending = _pending.contains(index);

    if (isBoolean) {
      final on = index < states.length && states[index];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: _ChannelLabel(
                name: name,
                description: description,
                colors: colors,
              ),
            ),
            if (pending)
              const _PendingIndicator()
            else if (canWrite)
              Switch(
                key: ValueKey('switch-channel-$index-toggle'),
                value: on,
                onChanged: (value) => _toggle(index, value),
              )
            else
              _ReadOnlyValue(label: on ? 'On' : 'Off', colors: colors),
          ],
        ),
      );
    }

    final min = index < state.channelMinValues.length
        ? state.channelMinValues[index]
        : 0.0;
    final max = index < state.channelMaxValues.length
        ? state.channelMaxValues[index]
        : 1.0;
    final hardwareValue =
        index < state.channelValues.length ? state.channelValues[index] : min;
    final validRange = min.isFinite && max.isFinite && max > min;
    final value = validRange
        ? (_analogDrafts[index] ?? hardwareValue).clamp(min, max).toDouble()
        : hardwareValue;
    final step =
        index < state.channelSteps.length ? state.channelSteps[index] : 0.0;
    final divisionCount = validRange && step.isFinite && step > 0
        ? ((max - min) / step).round()
        : 0;
    final divisions =
        divisionCount >= 1 && divisionCount <= 1000 ? divisionCount : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _ChannelLabel(
                  name: name,
                  description: description,
                  colors: colors,
                ),
              ),
              if (pending)
                const _PendingIndicator()
              else
                _ReadOnlyValue(
                  label: _formatValue(value),
                  colors: colors,
                  locked: !canWrite,
                ),
            ],
          ),
          if (validRange)
            Slider(
              key: ValueKey('switch-channel-$index-slider'),
              min: min,
              max: max,
              divisions: divisions,
              value: value,
              label: _formatValue(value),
              onChanged: canWrite && !pending
                  ? (next) => setState(() => _analogDrafts[index] = next)
                  : null,
              onChangeEnd: canWrite && !pending
                  ? (next) => _setValue(index, next)
                  : null,
            )
          else
            Text(
              'Driver reported an invalid numeric range',
              style:
                  SkotiqTypography.caption.copyWith(color: colors.warning),
            ),
        ],
      ),
    );
  }

  String _formatValue(double value) {
    if (!value.isFinite) return '—';
    if ((value - value.round()).abs() < 0.000001) {
      return value.toStringAsFixed(0);
    }
    return value.toStringAsFixed(2);
  }
}

class _ChannelLabel extends StatelessWidget {
  final String name;
  final String description;
  final SkotiqColors colors;

  const _ChannelLabel({
    required this.name,
    required this.description,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
        if (description.isNotEmpty)
          Text(
            description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
      ],
    );
  }
}

class _PendingIndicator extends StatelessWidget {
  const _PendingIndicator();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 24,
      height: 24,
      child: Padding(
        padding: EdgeInsets.all(4),
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

class _ReadOnlyValue extends StatelessWidget {
  final String label;
  final SkotiqColors colors;
  final bool locked;

  const _ReadOnlyValue({
    required this.label,
    required this.colors,
    this.locked = true,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (locked) ...[
          Icon(LucideIcons.lock, size: 12, color: colors.textMuted),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style:
              SkotiqTypography.readoutSm.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

/// Side of the switch panel's leading icon square, matching a device panel.
const double _switchIconSquare = 32.0;
