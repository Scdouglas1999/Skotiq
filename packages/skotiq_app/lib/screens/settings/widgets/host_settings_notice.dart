import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Says so when a linked client is showing some settings from its own
/// database because the imaging host is too old to share them. Shows nothing
/// on the machine that owns the hardware or when the host shares everything.
class HostSettingsNotice extends ConsumerWidget {
  const HostSettingsNotice({super.key});

  static const String title = 'Some settings are this computer\'s copy.';
  static const String message =
      'The imaging host runs an older Skotiq that does not share sequencer '
      'defaults, presets and similar settings. Update Skotiq on the host to see '
      'and change its values here.';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final support = ref.watch(hostSettingsStoreSupportProvider).valueOrNull;
    if (support != HostSettingsStoreSupport.legacy) {
      return const SizedBox.shrink();
    }
    return const Padding(
      padding: EdgeInsets.fromLTRB(
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceLg,
        0,
      ),
      child: SkotiqBanner(
        title: title,
        message: message,
        tone: BannerTone.warning,
      ),
    );
  }
}
