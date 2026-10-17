part of '../integrations_settings.dart';

/// The enable/disable switch bound to [pluginEnablementProvider.setEnabled],
/// which persists the choice AND drives the live host. Failures surface via
/// [ErrorDialog]; the toggle is never optimistically left in a wrong state.
class _PluginEnableSwitch extends ConsumerStatefulWidget {
  const _PluginEnableSwitch({
    required this.pluginId,
    required this.value,
    required this.enabled,
  });

  final String pluginId;
  final bool value;
  final bool enabled;

  @override
  ConsumerState<_PluginEnableSwitch> createState() =>
      _PluginEnableSwitchState();
}

class _PluginEnableSwitchState extends ConsumerState<_PluginEnableSwitch> {
  bool _busy = false;

  Future<void> _onChanged(bool next) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(pluginEnablementProvider.notifier)
          .setEnabled(widget.pluginId, next);
    } catch (error, stackTrace) {
      if (!mounted) return;
      await ErrorDialog.show(
        context,
        title: 'Could not update plugin',
        message:
            'Skotiq could not ${next ? 'enable' : 'disable'} this plugin. '
            'Its current state is unchanged.',
        technicalDetails: '$error\n$stackTrace',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SkotiqSwitch(
      value: widget.value,
      enabled: widget.enabled && !_busy,
      onChanged: _onChanged,
    );
  }
}
