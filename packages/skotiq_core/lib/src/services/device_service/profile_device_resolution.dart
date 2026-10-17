/// Which device a saved profile slot means, when its id is only a position.
///
/// Native vendor ids such as `native:zwo:0` or `native:zwo_eaf:1` are the
/// SDK's enumeration index, not an identity. The index follows USB order, so
/// plugging in a second camera can move the profile's camera from 0 to 1 while
/// the id saved in the profile still says 0. Connecting that id then opens
/// whichever camera now sits at 0. The profile also saves the device's name,
/// and that name is what this resolution checks the position against.
library;

import '../../models/backend/device_info.dart';

/// The outcome for one profile slot.
class ProfileSlotResolution {
  /// The id to connect. Null when the slot cannot be resolved safely.
  final String? deviceId;

  /// True when [deviceId] differs from the id the profile saved.
  final bool corrected;

  /// Why the slot was refused, for the operator. Set only when [deviceId] is
  /// null.
  final String? refusal;

  const ProfileSlotResolution.keep(String id)
    : deviceId = id,
      corrected = false,
      refusal = null;

  const ProfileSlotResolution.moved(String id)
    : deviceId = id,
      corrected = true,
      refusal = null;

  const ProfileSlotResolution.refused(String reason)
    : deviceId = null,
      corrected = false,
      refusal = reason;
}

/// `native:<vendor>:<index>`: the ids whose number is an enumeration position.
final RegExp _positionalNativeId = RegExp(r'^native:[a-z0-9_]+:\d+$');

/// Whether [id] names a position on the bus rather than a device.
bool isPositionalDeviceId(String id) => _positionalNativeId.hasMatch(id);

String _vendorPrefix(String id) => id.substring(0, id.lastIndexOf(':') + 1);

/// Discovery labels same-model devices "Name #2" or "Name (serial)"; the
/// profile saves the bare model name, so both sides are compared without the
/// suffix and without case or spacing differences.
String _normalizedName(String name) => name
    .replaceFirst(RegExp(r'\s*(#\d+|\([^)]*\))\s*$'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .toLowerCase();

/// Resolve the device a profile slot means.
///
/// [savedId] and [savedName] come from the profile; [discovered] is what
/// discovery currently reports for the slot's device type. Only positional
/// native ids are checked: other ids already name a driver or an address, and
/// a slot without a saved name has nothing to check against. When discovery
/// returned nothing, the position cannot be checked and the saved id is used.
ProfileSlotResolution resolveProfileSlot({
  required String savedId,
  required String? savedName,
  required String deviceLabel,
  required List<DeviceInfo> discovered,
}) {
  if (!isPositionalDeviceId(savedId) ||
      savedName == null ||
      savedName.trim().isEmpty ||
      discovered.isEmpty) {
    return ProfileSlotResolution.keep(savedId);
  }
  final wanted = _normalizedName(savedName);
  final prefix = _vendorPrefix(savedId);
  final sameVendor = discovered
      .where((d) => d.id.startsWith(prefix) && isPositionalDeviceId(d.id))
      .toList();

  DeviceInfo? atSaved;
  for (final d in sameVendor) {
    if (d.id == savedId) atSaved = d;
  }
  if (atSaved != null && _normalizedName(atSaved.name) == wanted) {
    return ProfileSlotResolution.keep(savedId);
  }

  final matches = sameVendor
      .where((d) => _normalizedName(d.name) == wanted)
      .toList();
  if (matches.length == 1) {
    return ProfileSlotResolution.moved(matches.single.id);
  }

  // Nothing at the saved position and no device of that name: the device is
  // unplugged. Let the connect fail on the saved id as it always has.
  if (atSaved == null && matches.isEmpty) {
    return ProfileSlotResolution.keep(savedId);
  }

  final found = atSaved == null
      ? 'nothing is at $savedId'
      : '$savedId is now ${atSaved.name}';
  final why = matches.isEmpty
      ? 'and no connected $deviceLabel has that name'
      : 'and ${matches.length} connected ${deviceLabel}s have that name';
  return ProfileSlotResolution.refused(
    'The profile\'s $deviceLabel is $savedName, but $found $why. '
    'Choose the $deviceLabel again in the profile so the right one connects.',
  );
}
