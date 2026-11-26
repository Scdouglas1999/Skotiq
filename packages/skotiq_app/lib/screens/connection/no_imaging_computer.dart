import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'link_rig_dialog.dart';
import 'work_locally.dart';

/// What a rig screen shows while this app has no imaging computer: the
/// equipment is run by Skotiq on the computer at the telescope, so there is
/// nothing here to scan or connect until one is linked.
///
/// In place of a scan that can only fail ("not connected to a Skotiq
/// Headless Server") on a phone that was opened without its rig.
class NoImagingComputerState extends StatelessWidget {
  const NoImagingComputerState({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: EmptyState(
          icon: LucideIcons.link,
          title: 'No imaging computer linked',
          body: 'Your camera, mount and the rest of the rig are run by '
              'Skotiq on the computer at the telescope. Link to it to see '
              'and connect them here.',
          action: Wrap(
            alignment: WrapAlignment.center,
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              SkotiqButton(
                label: 'Link to a computer',
                icon: LucideIcons.link,
                onPressed: () => unawaited(showLinkRigDialog(context)),
              ),
              if (canWorkLocally)
                const WorkLocallyButton(variant: ButtonVariant.secondary),
            ],
          ),
        ),
      ),
    );
  }
}
