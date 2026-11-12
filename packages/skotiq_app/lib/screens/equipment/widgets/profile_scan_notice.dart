import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';

/// Names the devices [profile] assigns that the last device scan did not
/// find, with a way to scan again. Says nothing until a scan has finished, and
/// never stands in the way of Connect all: a device the scan missed may still
/// answer when it is connected.
class ProfileScanNotice extends ConsumerStatefulWidget {
  const ProfileScanNotice({
    super.key,
    required this.profile,
    this.padding = EdgeInsets.zero,
  });

  final EquipmentProfileModel profile;

  /// Space around the notice, kept only while it shows.
  final EdgeInsetsGeometry padding;

  @override
  ConsumerState<ProfileScanNotice> createState() => _ProfileScanNoticeState();
}

class _ProfileScanNoticeState extends ConsumerState<ProfileScanNotice> {
  bool _scanning = false;

  /// What the notice said before the current scan started. A scan clears the
  /// devices of the drivers it is scanning, so without this the notice would
  /// vanish mid-scan and come back a few seconds later.
  ProfileScanCheck? _beforeScan;

  Future<void> _scanAgain() async {
    if (_scanning) return;
    final host = ref.backendScope();
    setState(() {
      _scanning = true;
      _beforeScan = ref.read(profileScanCheckProvider(widget.profile));
    });
    try {
      // Look at the buses now rather than answer from the last sweep, so a
      // device plugged in a moment ago is listed.
      await ref.read(deviceBackendProvider).rescanDevices();
      await ref.read(unifiedDiscoveryProvider.notifier).discoverAll();
    } catch (e) {
      if (mounted && host.isCurrent) {
        context.showErrorSnackBar('Scan failed: ${userFacingError(e)}');
      }
    } finally {
      if (mounted) {
        setState(() {
          _scanning = false;
          _beforeScan = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scanning =
        _scanning || ref.watch(unifiedDiscoveryProvider).isDiscovering;
    final current = ref.watch(profileScanCheckProvider(widget.profile));
    final check = scanning ? (_beforeScan ?? current) : current;
    final scannedAt = check.scannedAt;
    final missing = check.notFound;
    if (scannedAt == null || missing.isEmpty) return const SizedBox.shrink();

    final banner = SkotiqBanner(
      tone: BannerTone.warning,
      icon: LucideIcons.searchX,
      title: profileScanNoticeTitle(missing),
      message: profileScanNoticeMessage(missing, scannedAt.toLocal()),
      action: SkotiqButton(
        label: scanning ? 'Scanning…' : 'Scan again',
        icon: LucideIcons.refreshCw,
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
        isLoading: scanning,
        onPressed: scanning ? null : _scanAgain,
      ),
    );
    return Padding(padding: widget.padding, child: banner);
  }
}

@visibleForTesting
String profileScanNoticeTitle(List<ProfileDeviceNotFound> missing) =>
    missing.length == 1
        ? "This profile's ${missing.single.slot} was not found in the last scan."
        : "${missing.length} of this profile's devices were not found in the "
            'last scan.';

@visibleForTesting
String profileScanNoticeMessage(
  List<ProfileDeviceNotFound> missing,
  DateTime scannedAt,
) {
  final names = missing.length == 1
      ? missing.single.name
      : _andList([for (final d in missing) '${d.name} (${d.slot})']);
  final one = missing.length == 1;
  return '$names ${one ? 'was' : 'were'} not listed at '
      '${ClockFormat.hm(scannedAt)}. Check that ${one ? 'it is' : 'they are'} '
      'plugged in and powered, then scan again; Connect all still tries '
      '${one ? 'it' : 'them'}.';
}

String _andList(List<String> items) => items.length <= 1
    ? items.join()
    : '${items.sublist(0, items.length - 1).join(', ')} and ${items.last}';
