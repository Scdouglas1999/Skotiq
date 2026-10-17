// Delivery settings — the destinations tonight's artifacts are copied to.
//
// Scope: this page configures the v58 `delivery_targets` rows and reports what
// `delivery_journal` says happened to them. The Darkroom editor, the dawn job
// surface and the morning report are elsewhere.
//
// The honesty rule this page is built around: a destination row states only
// what the journal can support. A configured destination that has never run
// says "No delivery has run yet" — never "ready" or "delivering". A channel
// that goes nowhere (disabled, nothing selected, no path, no key in the
// keyring) says so in the same sentence slot, so the one line an operator
// reads at dawn is always the true one.
//
// Three destination kinds, three editing stances:
//   * Watched folder — path + a write probe that proves the directory is
//     writable right now. The probe never creates the directory: an unmounted
//     NAS mountpoint and a missing folder look identical, and creating it
//     would fill the boot drive with masters (same stance as
//     `WatchedFolderTransport`).
//   * SFTP — host/port/user/remote dir in `config_json`, private key in the OS
//     keyring under `secret_ref`. The key is written and never read back; the
//     row shows a masked indicator only. `config_json` rides export and
//     backup, so `assertNoSecretsInConfig` rejects any attempt to put key
//     material there — this editor never tries.
//   * Peer — read-only. The rig does not push to a peer; it publishes a
//     manifest a paired desktop pulls. The transport identity comes from
//     pairing, so this page shows the peer id and its pairing state and edits
//     only what delivery owns: whether it is on and what it receives.
//
// Remote mode: `delivery_targets` lives in the LOCAL profile database. A phone
// driving a remote host would be editing its own rows, not the rig's, so the
// page refuses to render the list and says where the destinations actually
// live rather than showing plausible-looking rows for the wrong machine.
//
// That refusal is gated on the client ROLE, not on the connection. A desktop
// launched with `--remote-host` that has not reached its rig yet is still that
// rig's client: its own `delivery_targets` table is one no dawn job will ever
// read, so a destination added there would sit forever in a database with no
// captures behind it. Gating on `isRemoteModeProvider` alone offered exactly
// that editor for the whole of the pre-handshake window and after every drop.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show PairedDevice, PairingDatabase;
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:path/path.dart' as p;

import '../../utils/confirm_dialog.dart';
import '../../utils/snackbar_helper.dart';
import '../../utils/user_facing_error.dart';
import 'widgets/settings_widgets.dart';

part 'delivery_settings/delivery_settings_store.dart';
part 'delivery_settings/delivery_status_line.dart';
part 'delivery_settings/destination_rows.dart';
part 'delivery_settings/destination_editor_dialog.dart';

/// Settings section for delivery destinations and their delivery journal.
class DeliverySettings extends ConsumerWidget {
  const DeliverySettings({super.key, this.isMobile = false});

  final bool isMobile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(isRemoteClientProvider)) {
      return _DeliveryRemoteModeNotice(isMobile: isMobile);
    }

    final destinations = ref.watch(deliveryDestinationsProvider);
    return destinations.when(
      loading: () => SettingsLoadingState(
        isMobile: isMobile,
        message: 'Reading delivery destinations...',
      ),
      error: (error, _) => SettingsErrorState(
        isMobile: isMobile,
        error: error,
        onRetry: () => ref.invalidate(deliveryDestinationsProvider),
      ),
      data: (read) => _DeliveryPageBody(isMobile: isMobile, read: read),
    );
  }
}

/// The page once the destinations have been read.
class _DeliveryPageBody extends ConsumerWidget {
  const _DeliveryPageBody({required this.isMobile, required this.read});

  final bool isMobile;
  final DeliveryDestinations read;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final views = read.views;
    final pushed = views
        .where((view) => view.destination.kind != ArtifactDestinationKind.peer)
        .toList(growable: false);
    final peers = views
        .where((view) => view.destination.kind == ArtifactDestinationKind.peer)
        .toList(growable: false);
    final unreadable = read.unreadable;

    return SettingsPage(
      title: 'Delivery',
      description:
          'Where the night\'s masters, renders and reports are copied once the '
          'dawn run finishes. Delivery copies — it never moves or deletes.',
      isMobile: isMobile,
      children: [
        SettingsSection(
          title: 'Delivery destinations',
          isMobile: isMobile,
          children: [
            if (pushed.isEmpty && unreadable.isEmpty)
              const _NoDestinationsRow()
            else ...[
              for (final view in pushed)
                _DestinationRow(
                  view: view,
                  isMobile: isMobile,
                  isLast: false,
                  key: ValueKey<int?>(view.destination.id),
                ),
              // Below the destinations that work, because these send nothing
              // and the operator's first question is about the ones that do.
              for (final row in unreadable)
                _UnreadableDestinationRow(
                  row: row,
                  isMobile: isMobile,
                  key: ValueKey<String>('unreadable-${row.id}-${row.name}'),
                ),
            ],
            _AddDestinationRow(isMobile: isMobile),
          ],
        ),
        // Only rendered when a peer destination row exists. Peer destinations
        // are written by pairing, not by this page, and an empty section
        // headed "Paired desktop pulls" would advertise a delivery path this
        // install has not been given.
        if (peers.isNotEmpty)
          SettingsSection(
            title: 'Paired desktop pulls',
            isMobile: isMobile,
            children: [
              for (var i = 0; i < peers.length; i++)
                _DestinationRow(
                  view: peers[i],
                  isMobile: isMobile,
                  isLast: i == peers.length - 1,
                  key: ValueKey<int?>(peers[i].destination.id),
                ),
            ],
          ),
      ],
    );
  }
}

/// What the page says instead of a destination list when this app is driving
/// someone else's rig.
class _DeliveryRemoteModeNotice extends StatelessWidget {
  const _DeliveryRemoteModeNotice({required this.isMobile});

  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    return SettingsPage(
      title: 'Delivery',
      description:
          'Where the night\'s masters, renders and reports are copied once the '
          'dawn run finishes.',
      isMobile: isMobile,
      children: const [
        EmptyState(
          icon: LucideIcons.server,
          title: 'Delivery destinations live on the imaging host',
          body:
              'Destinations are stored in the imaging host\'s own database and '
              'the files are copied from the host, not from this device. Open '
              'Settings on the host to add or change them.',
        ),
      ],
    );
  }
}
