import '../../armed_start_provider.dart';
import '../../host_scheduled_start_provider.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

/// The host's Start at dark: when its timer starts the loaded run, or nothing.
///
/// The host holds the schedule so the run starts whether or not a client is
/// awake or linked at dark; a client shows it, and its own arm and cancel
/// requests go to the host.
class ScheduledStartChannel extends RuntimeMirrorChannel<DateTime?> {
  const ScheduledStartChannel();

  @override
  String get key => 'scheduledStart';

  @override
  get source => nightArmedStartProvider;

  @override
  Map<String, dynamic>? encode(DateTime? value) =>
      value == null ? null : {'at': value.toUtc().toIso8601String()};

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (context.networkBackend == null) return;
    context.read(hostScheduledStartProvider.notifier).state =
        parseHostScheduledStart(jsonString(value?['at']));
  }
}
