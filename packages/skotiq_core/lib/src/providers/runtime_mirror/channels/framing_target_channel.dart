import '../../framing_provider.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

/// The target on the host's Framing screen, however the host got it: picked
/// on its own screen, sent by a client (`POST /api/framing/set-target`) or by
/// a script. A client that sets a target sends it to the host and gets it
/// back here.
class FramingTargetChannel extends RuntimeMirrorChannel<FramingTarget?> {
  const FramingTargetChannel();

  @override
  String get key => 'framingTarget';

  @override
  get source => framingProvider.select((state) => state.target);

  @override
  Map<String, dynamic>? encode(FramingTarget? value) {
    if (value == null) return null;
    final ra = finiteOrNull(value.raHours);
    final dec = finiteOrNull(value.decDegrees);
    if (ra == null || dec == null) return null;
    return {'ra': ra, 'dec': dec, 'name': value.name};
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    // A host without a target leaves the client's alone.
    if (value == null || context.networkBackend == null) return;
    final ra = requireDouble(value, 'ra');
    final dec = requireDouble(value, 'dec');
    final name = jsonString(value['name']);
    final shown = context.read(framingProvider).target;
    // The host's echo of a target this client set: applying it again would
    // reload the survey image and drop the aim point placed since.
    if (shown != null &&
        shown.raHours == ra &&
        shown.decDegrees == dec &&
        shown.name == name) {
      return;
    }
    context
        .read(framingProvider.notifier)
        .setTargetCoordinates(ra, dec, name: name, fromRemoteSync: true);
  }
}
