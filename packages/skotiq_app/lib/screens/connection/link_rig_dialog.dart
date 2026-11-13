import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// What the connect flow opens on.
class LinkRigRequest {
  /// Start by looking for imaging computers on the network.
  const LinkRigRequest.discover()
      : host = null,
        preferCode = false,
        fullAccess = false,
        refresh = false;

  /// Pair (again) with a known host: after its token was revoked, after it
  /// changed identity, or to gain full access with a code.
  const LinkRigRequest.pair(
    DiscoveredServer this.host, {
    this.preferCode = false,
    this.fullAccess = false,
    this.refresh = false,
  });

  /// Pair again with the remembered [rig].
  factory LinkRigRequest.repair(
    LinkedRig rig, {
    bool preferCode = false,
    bool fullAccess = false,
  }) =>
      LinkRigRequest.pair(
        DiscoveredServer(
          host: rig.host,
          webPort: rig.port,
          name: rig.name,
          scheme: rig.scheme,
          hostName: rig.name,
          platform: rig.platform,
          version: rig.version ?? 'unknown',
        ),
        preferCode: preferCode,
        fullAccess: fullAccess,
        refresh: true,
      );

  final DiscoveredServer? host;

  /// Ask [host] who it is before pairing: true for a host known only from a
  /// remembered record, whose identity may have changed since.
  final bool refresh;
  final bool preferCode;
  final bool fullAccess;
}

/// Opens "Connect to an imaging computer".
///
/// On success the rig is remembered and the app restarts as its linked client,
/// so the dialog does not return in that case.
Future<void> showLinkRigDialog(
  BuildContext context, {
  LinkRigRequest request = const LinkRigRequest.discover(),
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => LinkRigDialog(request: request),
  );
}

/// Asks a host for `/api/info`. A provider so widget tests answer offline.
final rigInfoFetcherProvider =
    Provider<Future<DiscoveredServer?> Function(DiscoveredServer host)>(
  (_) => (host) => RigDiscovery.fetchInfo(host),
);

enum _Phase { find, pair, linking, linked }

@visibleForTesting
class LinkRigDialog extends ConsumerStatefulWidget {
  const LinkRigDialog({super.key, required this.request});

  final LinkRigRequest request;

  @override
  ConsumerState<LinkRigDialog> createState() => _LinkRigDialogState();
}

class _LinkRigDialogState extends ConsumerState<LinkRigDialog> {
  _Phase _phase = _Phase.find;

  // Find.
  StreamSubscription<List<DiscoveredServer>>? _browse;
  List<DiscoveredServer> _found = const [];
  bool _browsing = false;
  final _manualHost = TextEditingController();
  final _manualPort = TextEditingController(text: '$kDefaultHeadlessPort');
  bool _checkingManual = false;
  String? _manualError;

  // Pair.
  DiscoveredServer? _host;
  bool _loadingHost = false;
  final _deviceName = TextEditingController(
    text: RigLinkService.defaultDeviceName(),
  );
  final _code = TextEditingController();
  final _codeFocus = FocusNode();
  bool _fullAccess = true;
  bool _busy = false;
  String? _error;
  bool _identityChanged = false;

  // A host with no screen makes its code on request and says where it put it.
  RemotePairingStartResult? _codeMade;
  bool _requestingCode = false;
  bool _oneTapRefused = false;

  // Linked.
  LinkedRig? _linked;

  @override
  void initState() {
    super.initState();
    final host = widget.request.host;
    if (host != null) {
      _fullAccess = widget.request.fullAccess || !host.lanPairing;
      unawaited(_openHost(host, refresh: widget.request.refresh));
    } else {
      _startBrowse();
    }
  }

  @override
  void dispose() {
    _browse?.cancel();
    _manualHost.dispose();
    _manualPort.dispose();
    _deviceName.dispose();
    _code.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- find

  void _startBrowse() {
    _browse?.cancel();
    setState(() {
      _browsing = true;
      _found = const [];
    });
    _browse = RigDiscovery.browse().listen(
      (list) {
        if (mounted) setState(() => _found = list);
      },
      onDone: () {
        if (mounted) setState(() => _browsing = false);
      },
      onError: (Object _) {
        if (mounted) setState(() => _browsing = false);
      },
    );
  }

  /// Hosts other than this computer's own server.
  List<DiscoveredServer> _visibleHosts() {
    final own = ref.watch(webServerStateProvider).serverFingerprint;
    if (own.isEmpty) return _found;
    return [
      for (final host in _found)
        if (host.fingerprint == null ||
            host.fingerprint!.toLowerCase() != own.toLowerCase())
          host,
    ];
  }

  Future<void> _checkManualAddress() async {
    // "192.168.1.32:8099" typed whole: the port goes to its own field.
    final typed = splitHostAndPort(_manualHost.text);
    if (typed.port != null) {
      _manualHost.text = typed.host;
      _manualPort.text = '${typed.port}';
    }
    final host = _manualHost.text.trim();
    final port = int.tryParse(_manualPort.text.trim());
    if (host.isEmpty) {
      setState(() => _manualError = 'Enter the computer name or IP address.');
      return;
    }
    if (port == null || port < 1 || port > 65535) {
      setState(() => _manualError = 'The port is a number from 1 to 65535.');
      return;
    }
    setState(() {
      _checkingManual = true;
      _manualError = null;
    });
    var found = await RigDiscovery.probeAddress(host, port);
    found ??= await RigDiscovery.probeAddress(host, port, scheme: 'https');
    if (!mounted) return;
    setState(() => _checkingManual = false);
    if (found == null) {
      setState(
        () => _manualError = 'Nothing at $host:$port answered as Skotiq. '
            'Check the address and that Remote access is on there.',
      );
      return;
    }
    await _openHost(found);
  }

  // ---------------------------------------------------------------- pair

  Future<void> _openHost(DiscoveredServer host, {bool refresh = false}) async {
    unawaited(_browse?.cancel());
    setState(() {
      _phase = _Phase.pair;
      _host = host;
      _error = null;
      _identityChanged = false;
      _codeMade = null;
      _oneTapRefused = false;
      _fullAccess = widget.request.fullAccess || !host.lanPairing;
    });
    if (!refresh) return;
    // A host reached from the remembered record: ask it who it is now, so the
    // fingerprint pinned for this pairing is the one on screen.
    setState(() => _loadingHost = true);
    final remembered = ref.read(launchLinkedRigProvider) ??
        await ref.read(linkedRigStoreProvider).load();
    final fresh = await ref.read(rigInfoFetcherProvider)(host);
    if (!mounted) return;
    setState(() {
      _loadingHost = false;
      if (fresh != null) {
        _host = fresh;
        _fullAccess = widget.request.fullAccess || !fresh.lanPairing;
        final before = remembered?.fingerprint;
        _identityChanged = before != null &&
            fresh.fingerprint != null &&
            before.toLowerCase() != fresh.fingerprint!.toLowerCase();
      } else {
        _error = "Can't reach ${host.displayName} at "
            '${host.host}:${host.webPort} right now.';
      }
    });
    if (widget.request.preferCode) _codeFocus.requestFocus();
  }

  Future<void> _pairOneTap() async {
    final host = _host;
    if (host == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pairing = await ref.read(rigLinkServiceProvider).pairOneTap(
            host,
            deviceName: _deviceNameValue(),
          );
      await _finish(host, pairing);
    } on RigPairingFailure catch (failure) {
      if (!mounted) return;
      final wantsCode =
          failure.kind == RigPairingFailureKind.oneTapUnavailable;
      if (wantsCode && _hasNoScreen(host)) {
        setState(() {
          _busy = false;
          _oneTapRefused = true;
        });
        await _requestCode();
        return;
      }
      setState(() {
        _busy = false;
        _error = _describe(failure, host);
      });
      if (wantsCode) _codeFocus.requestFocus();
    }
  }

  /// A headless host has no Remote access screen to show a code on.
  static bool _hasNoScreen(DiscoveredServer host) =>
      host.hostMode == 'headless';

  Future<void> _requestCode() async {
    final host = _host;
    if (host == null || _requestingCode) return;
    setState(() {
      _requestingCode = true;
      _error = null;
    });
    try {
      final made = await ref.read(rigLinkServiceProvider).requestCode(host);
      if (!mounted) return;
      setState(() {
        _requestingCode = false;
        _codeMade = made;
        _code.clear();
      });
      _codeFocus.requestFocus();
    } on RigPairingFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _requestingCode = false;
        _error = _describe(failure, host);
      });
    }
  }

  Future<void> _pairWithCode() async {
    final host = _host;
    if (host == null || _busy) return;
    final code = _code.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Type the code ${host.displayName} shows.');
      _codeFocus.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pairing = await ref.read(rigLinkServiceProvider).pairWithCode(
            host,
            code: code,
            deviceName: _deviceNameValue(),
            fullAccess: _fullAccess,
          );
      await _finish(host, pairing);
    } on RigPairingFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _describe(failure, host);
      });
    }
  }

  String _deviceNameValue() {
    final typed = _deviceName.text.trim();
    return typed.isEmpty ? RigLinkService.defaultDeviceName() : typed;
  }

  Future<void> _finish(DiscoveredServer host, RigPairing pairing) async {
    final service = ref.read(rigLinkServiceProvider);
    final rig = await service.remember(host, pairing);
    ref.invalidate(rememberedRigProvider);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _linked = rig;
      _phase = _Phase.linking;
    });
    final relauncher = ref.read(appRelauncherProvider);
    final restarted = relauncher != null &&
        await relauncher.relaunch(reason: 'Linked to ${rig.name}');
    if (!mounted) return;
    if (!restarted) setState(() => _phase = _Phase.linked);
  }

  String _describe(RigPairingFailure failure, DiscoveredServer host) {
    final name = host.displayName;
    switch (failure.kind) {
      case RigPairingFailureKind.oneTapUnavailable:
        return '$name asks for a pairing code. Type the code it shows below.';
      case RigPairingFailureKind.invalidCode:
        return "That code doesn't match the one $name shows. Check it and "
            'try again.';
      case RigPairingFailureKind.expiredCode:
        return _hasNoScreen(host)
            ? 'That code has expired or was already used. Press Get a new '
                  'code and type the one $name makes.'
            : 'That code has expired or was already used. Start pairing '
                  'again on $name and type the new code.';
      case RigPairingFailureKind.rateLimited:
        return '$name paused pairing after several wrong codes. Wait a '
            'minute and try again.';
      case RigPairingFailureKind.fingerprintMismatch:
        return 'The computer at ${host.host}:${host.webPort} is not the one '
            'listed. Nothing was sent to it. Search again.';
      case RigPairingFailureKind.unreachable:
        return "Can't reach $name at ${host.host}:${host.webPort}.";
      case RigPairingFailureKind.refused:
        return '$name refused the pairing: ${failure.message}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final canGoBack = _phase == _Phase.pair && widget.request.host == null;
    return SkotiqDialog(
      title: widget.request.fullAccess
          ? 'Link with admin access'
          : 'Connect to an imaging computer',
      icon: LucideIcons.monitorSmartphone,
      width: SkotiqDialog.widthForm,
      closeEnabled: _phase != _Phase.linking && !_busy,
      onClose: () => Navigator.of(context).pop(),
      actions: [
        if (canGoBack)
          SkotiqButton(
            label: 'Back',
            icon: LucideIcons.arrowLeft,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: _busy
                ? null
                : () {
                    setState(() {
                      _phase = _Phase.find;
                      _error = null;
                    });
                    _startBrowse();
                  },
          ),
        if (_phase == _Phase.linked)
          SkotiqButton(
            label: 'Restart now',
            icon: LucideIcons.refreshCw,
            size: ButtonSize.small,
            onPressed: () => unawaited(
              ref
                  .read(appRelauncherProvider)
                  ?.relaunch(reason: 'Linked to ${_linked?.name}'),
            ),
          )
        else if (_phase != _Phase.linking)
          SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
        child: switch (_phase) {
          _Phase.find => _buildFind(context),
          _Phase.pair => _buildPair(context),
          _Phase.linking => _buildLinking(context, restarting: true),
          _Phase.linked => _buildLinking(context, restarting: false),
        },
      ),
    );
  }

  Widget _buildFind(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final hosts = _visibleHosts();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Pick the computer your camera and mount are plugged into. Skotiq '
          'has to be open there with Remote access turned on.',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        Row(
          children: [
            Text(
              'ON THIS NETWORK',
              style: SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
            ),
            const Spacer(),
            SkotiqButton(
              label: _browsing ? 'Searching…' : 'Search again',
              icon: LucideIcons.refreshCw,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: _browsing ? null : _startBrowse,
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Container(
          width: double.infinity,
          decoration: SkotiqDecorations.well(colors),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < hosts.length; i++)
                _HostRow(
                  key: ValueKey('link.host.${hosts[i].host}:${hosts[i].webPort}'),
                  host: hosts[i],
                  showDivider: i < hosts.length - 1 || _browsing,
                  onLink: () => _openHost(hosts[i]),
                ),
              if (_browsing)
                const _StatusLine(
                  busy: true,
                  text: 'Looking for imaging computers…',
                )
              else if (hosts.isEmpty)
                const _StatusLine(
                  icon: LucideIcons.searchX,
                  text: 'No imaging computers answered. Check that Skotiq is '
                      'open on it, that Remote access is on, and that both '
                      'computers are on the same network. Or enter its '
                      'address below.',
                ),
            ],
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceXl),
        Text(
          'ENTER AN ADDRESS',
          style: SkotiqTypography.eyebrow.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: SkotiqTextField(
                key: const ValueKey('link.manual.host'),
                controller: _manualHost,
                hint: 'Computer name or IP, for example 192.168.1.32',
                prefixIcon: LucideIcons.monitor,
                dense: true,
                onSubmitted: (_) => _checkManualAddress(),
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            SizedBox(
              width: 96,
              child: SkotiqTextField(
                key: const ValueKey('link.manual.port'),
                controller: _manualPort,
                hint: 'Port',
                mono: true,
                dense: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onSubmitted: (_) => _checkManualAddress(),
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            SkotiqButton(
              label: 'Check',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              isLoading: _checkingManual,
              onPressed: _checkingManual ? null : _checkManualAddress,
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          _manualError ??
              'Skotiq listens on port $kDefaultHeadlessPort unless it was '
                  'changed there: see Settings > Remote access on that '
                  'computer, or the console of a headless one.',
          style: SkotiqTypography.caption.copyWith(
            color: _manualError == null ? colors.textMuted : colors.error,
          ),
        ),
      ],
    );
  }

  Widget _buildPair(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final host = _host!;
    final name = host.displayName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _HostSummary(host: host, loading: _loadingHost),
        if (_identityChanged) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqBanner(
            tone: BannerTone.warning,
            title: '$name has a new identity.',
            message: 'Its fingerprint is not the one this computer paired '
                'with. That happens after Skotiq is reinstalled there. Pair '
                'again only if you expected that.',
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceLg),
        SkotiqTextField(
          key: const ValueKey('link.deviceName'),
          controller: _deviceName,
          label: 'This computer is listed on $name as',
          prefixIcon: LucideIcons.tag,
          dense: true,
        ),
        // Asking for full access means the code: one tap grants control only.
        if (host.lanPairing && !widget.request.fullAccess) ...[
          const SizedBox(height: SkotiqTokens.spaceLg),
          Container(
            width: double.infinity,
            padding: SkotiqTokens.paddingMd,
            decoration: SkotiqDecorations.well(colors),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Link with one tap',
                  style: SkotiqTypography.labelStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  'Runs the rig from here: camera, mount, focuser, filter '
                  "wheel, guiding, sequences, profiles and $name's settings. "
                  'Stored passwords, backups, plugins and updates stay with '
                  '$name.',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                SkotiqButton(
                  key: const ValueKey('link.oneTap'),
                  label: 'Link to $name',
                  icon: LucideIcons.link,
                  isLoading: _busy,
                  onPressed: _busy || _loadingHost ? null : _pairOneTap,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceLg),
        Container(
          width: double.infinity,
          padding: SkotiqTokens.paddingMd,
          decoration: SkotiqDecorations.well(colors),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                host.lanPairing && !widget.request.fullAccess
                    ? 'Or pair with a code'
                    : 'Pair with a code',
                style: SkotiqTypography.labelStrong.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceXs),
              Text(
                _hasNoScreen(host)
                    ? '$name has no screen, so it keeps the code on its own '
                          'disk and never sends it over the network. Press '
                          'Get a code, then type the code from $name here, '
                          'for example ORBIT-NEBULA-4821.'
                    : 'On $name, open Settings > Remote access and press '
                          'Start pairing. Type the code it shows, for example '
                          'ORBIT-NEBULA-4821.',
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                  height: 1.4,
                ),
              ),
              if (_hasNoScreen(host)) ...[
                const SizedBox(height: SkotiqTokens.spaceMd),
                SkotiqButton(
                  key: const ValueKey('link.requestCode'),
                  label: _codeMade == null ? 'Get a code' : 'Get a new code',
                  icon: LucideIcons.keyRound,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  isLoading: _requestingCode,
                  onPressed: _busy || _loadingHost || _requestingCode
                      ? null
                      : _requestCode,
                ),
                if (_codeMade case final made?) ...[
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  _CodeWhereabouts(
                    key: const ValueKey('link.codeWhereabouts'),
                    text: describeCodeWhereabouts(
                      name,
                      made,
                      askedForCode: _oneTapRefused,
                    ),
                  ),
                ],
              ],
              const SizedBox(height: SkotiqTokens.spaceMd),
              Row(
                children: [
                  Expanded(
                    child: SkotiqTextField(
                      key: const ValueKey('link.code'),
                      controller: _code,
                      focusNode: _codeFocus,
                      hint: 'WORD-WORD-1234',
                      mono: true,
                      dense: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _pairWithCode(),
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  SkotiqButton(
                    key: const ValueKey('link.pairCode'),
                    label: 'Pair',
                    variant: host.lanPairing && !widget.request.fullAccess
                        ? ButtonVariant.secondary
                        : ButtonVariant.primary,
                    size: ButtonSize.small,
                    isLoading: _busy,
                    onPressed: _busy || _loadingHost ? null : _pairWithCode,
                  ),
                ],
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              MergeSemantics(
                child: Row(
                  children: [
                    SkotiqCheckbox(
                      value: _fullAccess,
                      onChanged: _busy
                          ? null
                          : (value) =>
                              setState(() => _fullAccess = value == true),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    Expanded(
                      child: GestureDetector(
                        onTap: _busy
                            ? null
                            : () => setState(() => _fullAccess = !_fullAccess),
                        child: Text(
                          "Also manage $name's stored passwords, backups, "
                          'plugins and updates from here',
                          style: SkotiqTypography.bodySm.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: SkotiqTokens.spaceLg),
          SkotiqBanner(
            key: const ValueKey('link.error'),
            tone: BannerTone.error,
            title: _error!,
          ),
        ],
      ],
    );
  }

  Widget _buildLinking(BuildContext context, {required bool restarting}) {
    final colors = SkotiqColors.of(context);
    final rig = _linked;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXl),
      child: Row(
        children: [
          if (restarting)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Icon(LucideIcons.checkCircle2, color: colors.success, size: 20),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Text(
              restarting
                  ? 'Linked to ${rig?.name}. Skotiq is restarting to run it '
                      'from here…'
                  : 'Linked to ${rig?.name}. Restart Skotiq to run it from '
                      'here.',
              style: SkotiqTypography.body.copyWith(color: colors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// `host:port` typed into the address field, split. An address with more than
/// one colon is IPv6 and is left whole unless written `[address]:port`.
@visibleForTesting
({String host, int? port}) splitHostAndPort(String raw) {
  final text = raw.trim();
  final match = RegExp(r'^\[(.+)\]:(\d{1,5})$').firstMatch(text) ??
      RegExp(r'^([^:]+):(\d{1,5})$').firstMatch(text);
  if (match == null) return (host: text, port: null);
  return (host: match.group(1)!, port: int.parse(match.group(2)!));
}

/// Where a headless host put the code it made, for the person who has to go
/// and read it: "home made a code, valid until 21:05. Read it from ...".
@visibleForTesting
String describeCodeWhereabouts(
  String name,
  RemotePairingStartResult made, {
  required bool askedForCode,
}) {
  final until = ClockFormat.hm(made.expiresAt.toLocal());
  final lead = askedForCode
      ? '$name asks for a code before it links a computer. It made one, '
            'valid until $until.'
      : '$name made a code, valid until $until.';
  final delivery = made.delivery;
  if (delivery == null) return '$lead Read it on $name.';
  final places = [
    if (delivery.operatorFile)
      'the file ${delivery.operatorFileName} in its Skotiq data folder (its '
          'console names that folder when Skotiq starts)',
    if (delivery.console) 'its console',
  ];
  if (places.isEmpty) {
    return '$name made a code but could not save it anywhere you can read. '
        'Start Skotiq there with --pairing-print-codes, then get a new code.';
  }
  return '$lead Read it on $name from ${places.join(', or from ')}.';
}

/// "Windows · Skotiq 8.2.1 · 192.168.1.32:8099"
@visibleForTesting
String describeDiscoveredHost(DiscoveredServer host) {
  final parts = <String>[];
  final os = switch (host.platform) {
    'windows' => 'Windows',
    'linux' => 'Linux',
    'macos' => 'macOS',
    'android' => 'Android',
    final other? when other.isNotEmpty => other,
    _ => null,
  };
  if (os != null) parts.add(os);
  if (host.hostMode == 'headless') parts.add('headless');
  if (host.version.isNotEmpty && host.version != 'unknown') {
    parts.add('Skotiq ${host.version}');
  }
  parts.add('${host.host}:${host.webPort}');
  return parts.join(' · ');
}

class _HostRow extends StatelessWidget {
  const _HostRow({
    super.key,
    required this.host,
    required this.showDivider,
    required this.onLink,
  });

  final DiscoveredServer host;
  final bool showDivider;
  final VoidCallback onLink;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final compatible = SkotiqServerCompatibility.check(
      host.apiVersion ?? host.version,
    ).isCompatible;
    return Container(
      decoration: showDivider
          ? BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.border)),
            )
          : null,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      child: Row(
        children: [
          Icon(LucideIcons.monitor, size: 18, color: colors.textMuted),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  host.displayName,
                  style: SkotiqTypography.labelStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  compatible
                      ? describeDiscoveredHost(host)
                      : '${describeDiscoveredHost(host)} · needs a matching '
                          'Skotiq version',
                  style: SkotiqTypography.caption.copyWith(
                    color: compatible ? colors.textMuted : colors.warning,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          SkotiqButton(
            label: 'Link',
            semanticsHint: 'Link to ${host.displayName}',
            size: ButtonSize.small,
            onPressed: compatible ? onLink : null,
          ),
        ],
      ),
    );
  }
}

class _CodeWhereabouts extends StatelessWidget {
  const _CodeWhereabouts({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(LucideIcons.info, size: 14, color: colors.info),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: Text(
            text,
            style: SkotiqTypography.caption.copyWith(
              color: colors.textPrimary,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.text, this.icon, this.busy = false});

  final String text;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Padding(
      padding: SkotiqTokens.paddingMd,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            Icon(icon, size: 16, color: colors.textMuted),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Text(
              text,
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HostSummary extends StatelessWidget {
  const _HostSummary({required this.host, required this.loading});

  final DiscoveredServer host;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final fingerprint = host.fingerprint;
    return Container(
      width: double.infinity,
      padding: SkotiqTokens.paddingMd,
      decoration: SkotiqDecorations.panel(colors),
      child: Row(
        children: [
          Icon(LucideIcons.monitor, size: 22, color: colors.primary),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  host.displayName,
                  style: SkotiqTypography.sectionTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  describeDiscoveredHost(host),
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                ),
                if (fingerprint != null && fingerprint.isNotEmpty)
                  Semantics(
                    label: 'Identity ${formatFingerprint(fingerprint)}',
                    excludeSemantics: true,
                    child: Text(
                      'Identity ${formatFingerprint(fingerprint)}',
                      style: SkotiqTypography.monoXs.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (loading)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }
}

/// First 16 hex digits in groups of four: `193f 004f 269f 2594`. The same
/// prefix the host's Remote access screen shows.
String formatFingerprint(String fingerprint) {
  final short = shortServerFingerprint(fingerprint.toLowerCase());
  final groups = <String>[];
  for (var i = 0; i < short.length; i += 4) {
    groups.add(short.substring(i, i + 4 > short.length ? short.length : i + 4));
  }
  return groups.join(' ');
}
