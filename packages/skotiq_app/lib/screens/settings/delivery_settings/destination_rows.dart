part of '../delivery_settings.dart';

/// Masked stand-in for a stored key. The keyring's value is written and never
/// read back into the UI, so this string is all the page can ever show.
const String kDeliverySecretPlaceholder = '•••••••• (stored in OS keyring)';

/// Icon for each transport.
IconData deliveryKindIcon(ArtifactDestinationKind kind) {
  switch (kind) {
    case ArtifactDestinationKind.watchedFolder:
      return LucideIcons.folder;
    case ArtifactDestinationKind.sftp:
      return LucideIcons.server;
    case ArtifactDestinationKind.peer:
      return LucideIcons.monitor;
  }
}

/// What each transport is called on screen.
String deliveryKindLabel(ArtifactDestinationKind kind) {
  switch (kind) {
    case ArtifactDestinationKind.watchedFolder:
      return 'Watched folder';
    case ArtifactDestinationKind.sftp:
      return 'SFTP';
    case ArtifactDestinationKind.peer:
      return 'Paired desktop pulls';
  }
}

/// The endpoint a destination writes to, rendered from its non-secret config.
String deliveryEndpointSummary(ArtifactDestination destination) {
  final config = decodeDestinationConfig(destination.configJson);
  switch (destination.kind) {
    case ArtifactDestinationKind.watchedFolder:
      final path = configString(config, 'path').trim();
      return path.isEmpty ? 'No folder set' : path;
    case ArtifactDestinationKind.sftp:
      final host = configString(config, 'host').trim();
      if (host.isEmpty) return 'No host set';
      final user = configString(config, 'user').trim();
      final port = configInt(config, 'port');
      final remoteDir = configString(config, 'remoteDir').trim();
      final authority = user.isEmpty ? host : '$user@$host';
      final withPort = port == null ? authority : '$authority:$port';
      return remoteDir.isEmpty ? withPort : '$withPort $remoteDir';
    case ArtifactDestinationKind.peer:
      final peerId = configString(config, 'peerId').trim();
      return peerId.isEmpty ? 'No peer id set' : peerId;
  }
}

/// The selected content classes, in the order the model serializes them.
String deliveryContentSummary(Set<ArtifactContent> content) {
  if (content.isEmpty) return 'Sends nothing';
  final names = <String>[];
  for (final entry in kArtifactContentLabels.entries) {
    if (content.contains(entry.key)) names.add(entry.value);
  }
  return 'Sends ${names.join(', ')}';
}

/// One destination in the list: what it is, what the journal says happened,
/// and the two controls delivery owns — on/off and edit.
class _DestinationRow extends ConsumerWidget {
  const _DestinationRow({
    super.key,
    required this.view,
    required this.isMobile,
    required this.isLast,
  });

  final DeliveryDestinationView view;
  final bool isMobile;
  final bool isLast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final destination = view.destination;
    final status = view.status;
    final id = destination.id;

    final detailStyle = SkotiqTypography.captionSm.copyWith(
      color: colors.textMuted,
    );

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12.0 : SkotiqTokens.spaceLg,
        vertical: isMobile ? 12.0 : 14.0,
      ),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(
                  color: colors.border.withValues(alpha: 0.5),
                ),
              ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: isMobile ? 32.0 : 36.0,
            height: isMobile ? 32.0 : 36.0,
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: SkotiqTokens.borderRadiusMd,
            ),
            child: Icon(
              deliveryKindIcon(destination.kind),
              size: isMobile ? 14.0 : SkotiqTokens.iconSm,
              color: colors.textSecondary,
            ),
          ),
          SizedBox(width: isMobile ? 10 : 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The description reads as ONE node — name, transport and
                // endpoint, what the journal says, what it sends — because six
                // fragments in a row is not how anyone reads a destination.
                // The merge stops here, at the text. A row-wide MergeSemantics
                // swallowed the switch's toggle state and the Edit button's tap
                // into the same node, so a screen reader was handed a single
                // checkable button named with the whole card, ending in "Edit
                // <name>", that did nothing when activated and offered no way
                // to reach either control.
                MergeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        destination.name,
                        style: (isMobile
                                ? SkotiqTypography.labelSm
                                : SkotiqTypography.label)
                            .copyWith(color: colors.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      // A remote directory or a deep mount path is long and has
                      // few break opportunities, so it is clipped rather than
                      // allowed to push the row past the card edge. The full
                      // value is in the editor, which is where it is changed.
                      Text(
                        '${deliveryKindLabel(destination.kind)} · '
                        '${deliveryEndpointSummary(destination)}',
                        style: detailStyle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: SkotiqTokens.spaceXs),
                      _StatusLine(status: status),
                      if (destination.kind == ArtifactDestinationKind.peer) ...[
                        const SizedBox(height: 2),
                        _PeerPairingLine(destination: destination),
                      ],
                      const SizedBox(height: 2),
                      Text(
                        deliveryContentSummary(destination.content),
                        style: detailStyle,
                      ),
                      if (destination.kind == ArtifactDestinationKind.sftp) ...[
                        const SizedBox(height: 2),
                        Text(_secretIndicator(view), style: detailStyle),
                      ],
                    ],
                  ),
                ),
                // The one state an operator can act on from here: every
                // attempt is spent, so nothing on the rig will look at those
                // files again until somebody says to. It follows the
                // description rather than interrupting it, the way a step
                // card's controls follow its text.
                if (status.kind == DeliveryStatusKind.failed && id != null)
                  _RetryNowButton(destination: destination, id: id),
              ],
            ),
          ),
          Flexible(
            child: Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                spacing: SkotiqTokens.spaceSm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // container, not a bare annotation: without a node of its own
                  // the switch's toggle state and tap action are absorbed by
                  // whatever node encloses it, which is how the whole row
                  // became one control carrying [ON].
                  Semantics(
                    container: true,
                    label: 'Deliver to ${destination.name}',
                    child: SkotiqSwitch(
                      value: destination.enabled,
                      onChanged: id == null
                          ? null
                          : (value) =>
                              _setEnabled(context, ref, id, value: value),
                    ),
                  ),
                  SkotiqIconButton(
                    icon: LucideIcons.settings2,
                    tooltip: 'Edit ${destination.name}',
                    onPressed: id == null
                        ? null
                        : () => _DestinationEditorDialog.edit(
                              context,
                              ref,
                              view: view,
                            ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _secretIndicator(DeliveryDestinationView view) {
    switch (view.secret) {
      case StoredSecretState.present:
        return 'SSH key: $kDeliverySecretPlaceholder';
      case StoredSecretState.absent:
        return 'SSH key: none stored';
      case StoredSecretState.unreadable:
        final error = view.secretError;
        if (error != null && error.trim().isNotEmpty) {
          return 'SSH key: the keyring could not be read (${error.trim()})';
        }
        return 'SSH key: the keyring could not be read';
    }
  }

  static Future<void> _setEnabled(
    BuildContext context,
    WidgetRef ref,
    int id, {
    required bool value,
  }) async {
    try {
      await ref
          .read(deliverySettingsStoreProvider)
          .updateDestination(id, enabled: value);
    } catch (error) {
      if (context.mounted) {
        context.showErrorSnackBar(
          'Could not change this destination: ${userFacingError(error)}',
        );
      }
    }
    ref.invalidate(deliveryDestinationsProvider);
  }
}

/// One `delivery_targets` row this build cannot decode.
///
/// Rendered as a row of its own rather than as the page's error state: the row
/// sends nothing, and the operator needs to see WHICH destination that is and
/// what is wrong with it while the destinations that do work are still on
/// screen. Only Delete is offered — every editing path reads the row through
/// the same decode that just refused it, so an editor opened here would have
/// nothing to render.
class _UnreadableDestinationRow extends ConsumerStatefulWidget {
  const _UnreadableDestinationRow({
    super.key,
    required this.row,
    required this.isMobile,
  });

  final UndecodableDeliveryTarget row;
  final bool isMobile;

  @override
  ConsumerState<_UnreadableDestinationRow> createState() =>
      _UnreadableDestinationRowState();
}

class _UnreadableDestinationRowState
    extends ConsumerState<_UnreadableDestinationRow> {
  bool _deleting = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final row = widget.row;
    final id = row.id;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: widget.isMobile ? 12.0 : SkotiqTokens.spaceLg,
        vertical: widget.isMobile ? 12.0 : 14.0,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.border.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: widget.isMobile ? 32.0 : 36.0,
            height: widget.isMobile ? 32.0 : 36.0,
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: SkotiqTokens.borderRadiusMd,
            ),
            child: Icon(
              LucideIcons.fileWarning,
              size: widget.isMobile ? 14.0 : SkotiqTokens.iconSm,
              color: colors.error,
            ),
          ),
          SizedBox(width: widget.isMobile ? 10 : 14),
          Expanded(
            // Same split as a readable row: the description is one node, and
            // Delete — the only thing this row can do — keeps its own. Merged
            // together, the single destructive control on the page arrived as a
            // 4-line name ending in "Delete".
            child: MergeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row.label,
                    style: (widget.isMobile
                            ? SkotiqTypography.labelSm
                            : SkotiqTypography.label)
                        .copyWith(color: colors.textPrimary),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  _StatusLine(
                    status: DeliveryStatusLine(
                      DeliveryStatusKind.failed,
                      'This row cannot be read, so nothing is sent here: '
                      '${row.reason}.',
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Every other destination delivers normally. Deleting this '
                    'row removes it and its delivery journal; files already '
                    'delivered are left alone.',
                    style: SkotiqTypography.captionSm.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (id != null)
            Flexible(
              child: Align(
                alignment: Alignment.centerRight,
                child: SkotiqButton(
                  label: 'Delete',
                  icon: LucideIcons.trash2,
                  variant: ButtonVariant.destructive,
                  size: ButtonSize.small,
                  isLoading: _deleting,
                  onPressed: _deleting ? null : () => _delete(id),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _delete(int id) async {
    final confirmed = await ConfirmDialog.show(
      context: context,
      title: 'Delete ${widget.row.label}?',
      message: 'This destination cannot be read, so it delivers nothing. '
          'Deleting removes the row and its delivery journal. Files already '
          'delivered there are left alone — delivery copies, it never moves.',
      confirmLabel: 'Delete',
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _deleting = true);
    try {
      await ref.read(deliverySettingsStoreProvider).deleteDestination(id);
    } catch (error) {
      if (mounted) {
        context.showErrorSnackBar(
          'Could not delete this destination: ${userFacingError(error)}',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _deleting = false);
        ref.invalidate(deliveryDestinationsProvider);
      }
    }
  }
}

/// Re-queues every spent row a destination holds — across every job — and runs
/// a sweep.
///
/// Shown only beside a `failed` status line, because that is the only state
/// where nothing else is going to happen: `retrying` rows are already on the
/// sweep's list and a second push at them would only reset a backoff that is
/// doing its job. The status line beside it counts terminal rows across every
/// job, so this button reaches exactly as far — it is the action for that
/// sentence, and re-queueing less than the sentence counts would report work
/// it did not do.
class _RetryNowButton extends ConsumerStatefulWidget {
  const _RetryNowButton({required this.destination, required this.id});

  final ArtifactDestination destination;
  final int id;

  @override
  ConsumerState<_RetryNowButton> createState() => _RetryNowButtonState();
}

class _RetryNowButtonState extends ConsumerState<_RetryNowButton> {
  bool _running = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceXs),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          label: 'Retry delivery to ${widget.destination.name}',
          child: SkotiqButton(
            label: 'Retry now',
            icon: LucideIcons.refreshCw,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            isLoading: _running,
            onPressed: _running ? null : _retry,
          ),
        ),
      ),
    );
  }

  Future<void> _retry() async {
    setState(() => _running = true);
    final name = widget.destination.name;
    try {
      final store = ref.read(deliverySettingsStoreProvider);
      final requeued = await store.requeueTerminalRows(widget.id);
      if (requeued == 0) {
        // The journal moved under the page — a sweep or a fresh run already
        // took these rows. Saying "re-queued 0 files" would be a report of
        // work that did not need doing, not of work that failed.
        if (mounted) {
          context.showInfoSnackBar(
            'Nothing on $name is waiting to be retried any more; the list is '
            'reloading.',
          );
        }
        return;
      }
      final report = await ref.read(deliverySweepRequestProvider)();
      if (!mounted) return;
      context.showInfoSnackBar(_outcomeSentence(name, requeued, report));
    } catch (error) {
      if (mounted) {
        context.showErrorSnackBar(
          'Could not retry delivery to $name: ${userFacingError(error)}',
        );
      }
    } finally {
      // Both calls need a live element: `ref` on a disposed ConsumerState
      // throws. A page the operator left behind re-reads the journal when it
      // is opened again, because the destinations provider is autoDispose.
      if (mounted) {
        setState(() => _running = false);
        ref.invalidate(deliveryDestinationsProvider);
      }
    }
  }

  /// What the sweep actually did with the re-queued files.
  ///
  /// A null [report] is a sweep that was already running when this one asked:
  /// that pass read its work list before these rows went back on it, so the
  /// files wait for the next tick. Saying they are being delivered right now
  /// would be the claim this page exists to avoid.
  String _outcomeSentence(
      String name, int requeued, DeliveryRunReport? report) {
    final files = requeued == 1 ? '1 file' : '$requeued files';
    if (report == null) {
      return 'Re-queued $files for $name with a fresh attempt budget. A '
          'delivery sweep was already running, so the next one takes them.';
    }
    for (final swept in report.destinations) {
      if (swept.targetId == widget.id) {
        return 'Re-queued $files for $name, then the sweep reported '
            '${_sweptCounts(swept)}.';
      }
    }
    return 'Re-queued $files for $name with a fresh attempt budget. The sweep '
        'that ran did not reach this destination, so the next one takes them.';
  }

  /// The sweep's own counts for this destination, so the sentence states what
  /// happened to the files rather than that something happened.
  static String _sweptCounts(DeliveryDestinationReport swept) {
    final parts = <String>[
      if (swept.delivered > 0) '${swept.delivered} delivered',
      if (swept.awaitingPull > 0) '${swept.awaitingPull} awaiting a pull',
      if (swept.retrying > 0) '${swept.retrying} owed another attempt',
      if (swept.suspended > 0)
        '${swept.suspended} suspended while the destination is switched off',
      if (swept.failed > 0) '${swept.failed} failed again',
      if (swept.unjournalled > 0) '${swept.unjournalled} not journalled',
    ];
    return parts.isEmpty ? 'nothing was attempted' : parts.join(', ');
  }
}

/// The status dot plus its sentence.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.status});

  final DeliveryStatusLine status;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final color = deliveryStatusColor(status.kind, colors);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: StatusDot(color: color, size: 7),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: Text(
            status.sentence,
            style: SkotiqTypography.captionSm.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// What actually gates a peer pull, stated on every peer row.
///
/// Kept next to the pairing line because the pairing line is the half an
/// operator reads as the gate, and it is not: the routes check the token, and
/// the peer id only picks which destination's file list is served.
const String _peerPullAuthSentence =
    'These files are served to any client holding this rig\'s access token '
    'that asks as this peer id — the pairing list does not gate the pull.';

/// Whether a paired desktop is registered under this peer destination's id.
///
/// **What this line may and may not claim.** The pairing store is a register of
/// desktops the operator has paired; it is NOT what gates a pull. The three
/// peer routes — `GET /api/darkroom/delivery/manifest/<job>`,
/// `GET .../artifact/<job>/<id>` and `POST .../ack/<job>` — authenticate with
/// the rig's ordinary access token (view scope reads the manifest and the
/// bytes, control acknowledges) and `PeerManifestService` resolves `?peer=`
/// against `delivery_targets` alone. So an empty pairing list means nobody is
/// REGISTERED under that name, not that nothing can collect the files: a
/// desktop holding the rig's token and asking as that peer id completes the
/// whole pull with the pairing store empty. This line used to say "so nothing
/// can pull these files", which was the opposite of what the same build does.
class _PeerPairingLine extends ConsumerWidget {
  const _PeerPairingLine({required this.destination});

  final ArtifactDestination destination;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final style = SkotiqTypography.captionSm.copyWith(
      color: colors.textMuted,
    );
    final config = decodeDestinationConfig(destination.configJson);
    final peerId = configString(config, 'peerId').trim();
    if (peerId.isEmpty) {
      return Text('Pairing: no peer id to match', style: style);
    }

    final devices = ref.watch(deliveryPairedDesktopsProvider);
    return devices.when(
      loading: () => Text('Pairing: reading the paired devices…', style: style),
      error: (error, _) => Text(
        'Pairing: the paired-device list could not be read '
        '(${userFacingError(error)})',
        style: style.copyWith(color: colors.warning),
      ),
      data: (list) {
        final match = _matchFor(list, peerId);
        if (match == null) {
          return Text(
            'Pairing: no paired desktop is registered under "$peerId". '
            '$_peerPullAuthSentence',
            style: style.copyWith(color: colors.warning),
          );
        }
        final lastSeen = match.lastConnectedAt;
        final seen = lastSeen == null
            ? 'not connected since pairing'
            : 'last connected '
                '${DateFormat('d MMM HH:mm').format(lastSeen.toLocal())}';
        return Text(
          'Pairing: ${match.deviceName} ($seen). $_peerPullAuthSentence',
          style: style,
        );
      },
    );
  }

  /// A peer destination names its desktop by the identity that desktop sends
  /// when it asks for a manifest, which is the paired device id. Matching the
  /// display name too is deliberate: an operator who typed the name they see
  /// in the pairing list gets the truth rather than a false "not paired".
  static PairedDevice? _matchFor(List<PairedDevice> devices, String peerId) {
    for (final device in devices) {
      if (device.deviceId == peerId) return device;
    }
    for (final device in devices) {
      if (device.deviceName == peerId) return device;
    }
    return null;
  }
}

/// What the destinations card shows before anything is configured.
class _NoDestinationsRow extends StatelessWidget {
  const _NoDestinationsRow();

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: colors.border.withValues(alpha: 0.5)),
        ),
      ),
      child: const EmptyState.compact(
        icon: LucideIcons.send,
        title: 'No delivery destination',
        body: 'Nothing is copied off this machine after a dawn run. Add a '
            'watched folder or an SFTP host to change that.',
      ),
    );
  }
}

/// The two add buttons, in the card's last row.
class _AddDestinationRow extends ConsumerWidget {
  const _AddDestinationRow({required this.isMobile});

  final bool isMobile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 12.0 : SkotiqTokens.spaceLg,
        vertical: isMobile ? 12.0 : 14.0,
      ),
      child: Wrap(
        spacing: SkotiqTokens.spaceSm,
        runSpacing: SkotiqTokens.spaceSm,
        children: [
          SkotiqButton(
            label: 'Add watched folder',
            icon: LucideIcons.folderPlus,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => _DestinationEditorDialog.create(
              context,
              ref,
              kind: ArtifactDestinationKind.watchedFolder,
            ),
          ),
          SkotiqButton(
            label: 'Add SFTP destination',
            icon: LucideIcons.serverCog,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => _DestinationEditorDialog.create(
              context,
              ref,
              kind: ArtifactDestinationKind.sftp,
            ),
          ),
        ],
      ),
    );
  }
}
