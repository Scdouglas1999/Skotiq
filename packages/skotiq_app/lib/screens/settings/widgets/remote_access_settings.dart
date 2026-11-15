import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../connection/linked_rig_panel.dart';
import '../pairing_screen.dart' show PairingSettings, pairingProvider;
import 'admin_only.dart';
import 'settings_widgets.dart';
import '../../../utils/snackbar_helper.dart';

part 'remote_access_settings/shared_controls.dart';
part 'remote_access_settings/tailscale_panel.dart';
part 'remote_access_settings/status_rows.dart';

class RemoteAccessSettings extends ConsumerStatefulWidget {
  const RemoteAccessSettings({
    super.key,
  });

  @override
  ConsumerState<RemoteAccessSettings> createState() =>
      _RemoteAccessSettingsState();
}

class _RemoteAccessSettingsState extends ConsumerState<RemoteAccessSettings> {
  late TextEditingController _portController;
  late FocusNode _portFocusNode;
  Future<void> _portWriteTail = Future<void>.value();
  int _portEditGeneration = 0;
  int _pendingPortWrites = 0;
  int? _lastSubmittedPort;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController();
    _portFocusNode = FocusNode();
    _portFocusNode.addListener(() {
      if (!_portFocusNode.hasFocus) {
        final settings = ref.read(appSettingsProvider).valueOrNull;
        if (settings != null) {
          _commitPort(settings, showFeedback: false);
        }
      }
    });
  }

  @override
  void dispose() {
    _portController.dispose();
    _portFocusNode.dispose();
    super.dispose();
  }

  void _commitPort(
    AppSettingsState settings, {
    required bool showFeedback,
  }) {
    final port = int.tryParse(_portController.text);
    if (port != null && port >= 1024 && port <= 65535) {
      if (port == settings.webServerPort || port == _lastSubmittedPort) {
        _lastSubmittedPort = port;
        return;
      }

      _lastSubmittedPort = port;
      final generation = ++_portEditGeneration;
      final notifier = ref.read(appSettingsProvider.notifier);
      _pendingPortWrites++;
      final operation = _portWriteTail.then((_) async {
        try {
          await notifier.setWebServerPort(port);
        } catch (_) {
          if (!mounted || generation != _portEditGeneration) return;
          final confirmed =
              ref.read(appSettingsProvider).valueOrNull?.webServerPort ??
                  settings.webServerPort;
          _lastSubmittedPort = confirmed;
          final restored = confirmed.toString();
          _portController.value = TextEditingValue(
            text: restored,
            selection: TextSelection.collapsed(offset: restored.length),
          );
          context.showInfoSnackBar(
            context.l10n.text('remoteAccessSavePortFailed'),
            duration: const Duration(seconds: 2),
          );
        } finally {
          _pendingPortWrites--;
        }
      });
      _portWriteTail = operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      );
      unawaited(operation);
      return;
    }

    final confirmed =
        ref.read(appSettingsProvider).valueOrNull?.webServerPort ??
            settings.webServerPort;
    _lastSubmittedPort = confirmed;
    ++_portEditGeneration;
    _portController.text = confirmed.toString();
    if (showFeedback && mounted) {
      context.showInfoSnackBar(
        context.l10n.text('remoteAccessInvalidPort'),
        duration: const Duration(seconds: 2),
      );
    }
  }

  Future<void> _copyUrl(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) {
      return;
    }
    context.showInfoSnackBar(
      context.l10n.text(
        'remoteAccessCopiedUrl',
        params: {'url': url},
      ),
      duration: const Duration(seconds: 2),
    );
  }

  Future<void> _openUrl(String url) async {
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      await Clipboard.setData(ClipboardData(text: url));
      if (!mounted) {
        return;
      }
      context.showInfoSnackBar(
        context.l10n.text('remoteAccessOpenFailed'),
        duration: const Duration(seconds: 2),
      );
    }
  }

  /// Re-run the desktop's network-interface enumeration so a tailnet address
  /// that came up *after* the server started (operator launched Tailscale, or
  /// `tailscale up` finished negotiating an address) is picked up without
  /// toggling the whole web server off and on.
  ///
  /// [WebServerStateNotifier] re-resolves the local/tailnet IPs as a side
  /// effect of [WebServerStateNotifier.setRunning]; we replay the *current*
  /// running parameters so every persisted field round-trips unchanged and the
  /// only observable effect is a fresh interface scan. We never invalidate the
  /// provider here — that would drop the runtime state (port, fingerprint,
  /// auth) that the bootstrap injected at startup.
  void _recheckTailscale(WebServerState webState) {
    ref.read(webServerStateProvider.notifier).setRunning(
          isRunning: webState.isRunning,
          actualPort: webState.actualPort,
          configuredPort: webState.configuredPort,
          bindLocalOnly: webState.bindLocalOnly,
          requiresAuthentication: webState.requiresAuthentication,
          dashboardAvailable: webState.dashboardAvailable,
          lastError: webState.lastError,
          serverFingerprint: webState.serverFingerprint,
        );
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);
    final webState = ref.watch(webServerStateProvider);
    final pairingState = ref.watch(pairingProvider);
    final appVersion = ref.watch(appVersionProvider);
    // On a remote client (phone/tablet paired to a host) the local
    // webServerStateProvider never runs, while `webServerEnabled` mirrors the
    // HOST's setting — without this the pane shows "Starting remote access"
    // forever. Being connected at all proves the host's server is up.
    final isRemote = ref.watch(isRemoteModeProvider);
    final hostLink = ref.watch(linkedHostLinkProvider);
    final l10n = context.l10n;

    return settingsAsync.when(
      loading: () => const SettingsLoadingState(),
      error: (error, stack) => SettingsErrorState(
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        if (!_portFocusNode.hasFocus &&
            _pendingPortWrites == 0 &&
            _portController.text != settings.webServerPort.toString()) {
          _portController.text = settings.webServerPort.toString();
          _lastSubmittedPort = settings.webServerPort;
        }

        final showDetails =
            settings.webServerEnabled || webState.lastError.isNotEmpty;

        return SettingsPage(
          title: l10n.text('remoteAccessTitle'),
          description: l10n.text('remoteAccessDescription'),
          children: [
            // Which computer runs the rig comes first: on a linked desktop
            // everything below describes the imaging computer, not this one.
            const LinkedRigPanel(),
            SettingsSection(
              title: l10n.text('remoteAccessWebServer'),
              children: [
                SettingRow(
                  icon: LucideIcons.globe,
                  title: l10n.text('remoteAccessEnableTitle'),
                  subtitle: l10n.text('remoteAccessEnableDesc'),
                  trailing: AdminOnlyControl(
                    child: SettingsSwitch(
                      value: settings.webServerEnabled,
                      onChanged: (value) {
                        return ref
                            .read(appSettingsProvider.notifier)
                            .setWebServerEnabled(value);
                      },
                    ),
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.hash,
                  title: l10n.text('remoteAccessPortTitle'),
                  subtitle: l10n.text('remoteAccessPortDesc'),
                  trailing: AdminOnlyControl(
                    text: 'Port ${settings.webServerPort}. $adminOnlyAdvice',
                    child: SizedBox(
                      width: 100,
                      child: TextField(
                        key: const ValueKey('remote-access-port'),
                        controller: _portController,
                        focusNode: _portFocusNode,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          _PortRangeFormatter(),
                        ],
                        style: SkotiqTypography.bodySm.copyWith(
                          color: SkotiqColors.of(context).textPrimary,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(SkotiqTokens.radiusMd),
                            borderSide: BorderSide(
                                color: SkotiqColors.of(context).border),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(SkotiqTokens.radiusMd),
                            borderSide: BorderSide(
                                color: SkotiqColors.of(context).border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius:
                                BorderRadius.circular(SkotiqTokens.radiusMd),
                            borderSide: BorderSide(
                              color: SkotiqColors.of(context).primary,
                              width: 2,
                            ),
                          ),
                          filled: true,
                          fillColor: SkotiqColors.of(context).well,
                        ),
                        onTapOutside: (_) =>
                            _commitPort(settings, showFeedback: true),
                        onSubmitted: (_) =>
                            _commitPort(settings, showFeedback: true),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            SettingsSection(
              title: 'Open the dashboard',
              children: [
                if (isRemote)
                  SettingRow(
                    icon: LucideIcons.wifi,
                    title: l10n.text('remoteAccessHostActiveTitle'),
                    subtitle: l10n.text('remoteAccessHostActiveBody'),
                    trailing: const SizedBox.shrink(),
                  )
                else if (webState.lastError.isNotEmpty)
                  SettingsItem(
                    child: SkotiqBanner(
                      tone: BannerTone.error,
                      title: l10n.text('remoteAccessIssueTitle'),
                      // The cause first, in plain words; the raw text is
                      // under Connection details with a copy button.
                      message: '${explainRemoteAccessError(
                        webState.lastError,
                        webState.configuredPort,
                      )}\n${l10n.text('remoteAccessIssueBody')}',
                    ),
                  )
                else if (webState.isRunning) ...[
                  _DashboardLinkRow(
                    title: l10n.text('remoteAccessLocalActionTitle'),
                    description: describeLocalDashboardAction(
                      requiresAuthentication: webState.requiresAuthentication,
                    ),
                    url: webState.localUrl,
                    actions: [
                      SkotiqButton(
                        label: l10n.text('remoteAccessOpenLocal'),
                        icon: LucideIcons.externalLink,
                        variant: ButtonVariant.secondary,
                        size: ButtonSize.small,
                        onPressed: () => _openUrl(webState.localUrl),
                      ),
                      SkotiqButton(
                        label: l10n.text('remoteAccessCopyLink'),
                        icon: LucideIcons.copy,
                        variant: ButtonVariant.ghost,
                        size: ButtonSize.small,
                        onPressed: () => _copyUrl(webState.localUrl),
                      ),
                    ],
                  ),
                  if (webState.networkUrl.isNotEmpty)
                    _DashboardLinkRow(
                      title: l10n.text('remoteAccessLanActionTitle'),
                      description: l10n.text(
                        webState.requiresAuthentication
                            ? 'remoteAccessLanActionBodyPaired'
                            : 'remoteAccessLanActionBodyOpen',
                      ),
                      url: webState.networkUrl,
                      actions: [
                        SkotiqButton(
                          label: l10n.text('remoteAccessCopyLan'),
                          icon: LucideIcons.copy,
                          variant: ButtonVariant.secondary,
                          size: ButtonSize.small,
                          onPressed: () => _copyUrl(webState.networkUrl),
                        ),
                        SkotiqButton(
                          label: l10n.text('remoteAccessOpenLink'),
                          icon: LucideIcons.externalLink,
                          variant: ButtonVariant.ghost,
                          size: ButtonSize.small,
                          onPressed: () => _openUrl(webState.networkUrl),
                        ),
                      ],
                    ),
                ] else
                  SettingRow(
                    icon: LucideIcons.power,
                    title: settings.webServerEnabled
                        ? l10n.text('remoteAccessStartingTitle')
                        : l10n.text('remoteAccessDisabledTitle'),
                    subtitle: settings.webServerEnabled
                        ? l10n.text('remoteAccessStartingBody')
                        : l10n.text('remoteAccessDisabledBody'),
                    trailing: settings.webServerEnabled
                        ? const SkotiqSpinner(size: 16)
                        : const SizedBox.shrink(),
                  ),
                SettingRow(
                  icon: LucideIcons.shield,
                  title: 'Who can connect',
                  subtitle: describeRemoteAccessPairing(
                    requiresAuthentication: webState.requiresAuthentication,
                    linkedHost: hostLink?.serverHost,
                    hostRequiresPairing: hostLink?.hostRequiresPairing,
                  ),
                  trailing: const SizedBox.shrink(),
                ),
              ],
            ),
            // A linked client pairs nothing itself: phones and browsers pair
            // with the imaging computer that serves them.
            if (!isRemote) const PairingSettings(),
            if (webState.isRunning &&
                webState.serverFingerprint.isNotEmpty) ...[
              _RemoteTailscalePanel(
                webState: webState,
                pairingCode: pairingState.pairingCode,
                appVersion: appVersion.version,
                onStartPairing: pairingState.pairingCode == null
                    ? () => ref.read(pairingProvider.notifier).startPairing()
                    : null,
                onRecheck: () => _recheckTailscale(webState),
              ),
              const SizedBox(height: SkotiqTokens.space2xl),
            ],
            if (showDetails)
              SettingsSection(
                title: l10n.text('remoteAccessDetailsTitle'),
                children: [
                  _StatusRow(
                    icon: webState.isRunning
                        ? LucideIcons.checkCircle2
                        : LucideIcons.xCircle,
                    iconColor: webState.isRunning
                        ? SkotiqColors.of(context).success
                        : SkotiqColors.of(context).textMuted,
                    label: l10n.text('remoteAccessServerStatus'),
                    value: webState.isRunning
                        ? l10n.text('remoteAccessRunning')
                        : l10n.text('remoteAccessStopped'),
                  ),
                  _StatusRow(
                    icon: LucideIcons.shield,
                    iconColor: webState.requiresAuthentication
                        ? SkotiqColors.of(context).primary
                        : SkotiqColors.of(context).textMuted,
                    label: l10n.text('remoteAccessAuth'),
                    value: webState.requiresAuthentication
                        ? l10n.text('remoteAccessAuthRequired')
                        : l10n.text('remoteAccessAuthNotRequired'),
                  ),
                  _StatusRow(
                    icon: LucideIcons.wifi,
                    iconColor: webState.bindLocalOnly
                        ? SkotiqColors.of(context).textMuted
                        : SkotiqColors.of(context).primary,
                    label: l10n.text('remoteAccessScope'),
                    value: webState.bindLocalOnly
                        ? l10n.text('remoteAccessScopeLocal')
                        : l10n.text('remoteAccessScopeLan'),
                  ),
                  // About the bundled dashboard FILES, not reachability: it
                  // claims success only while the server is running.
                  _StatusRow(
                    icon: LucideIcons.monitor,
                    iconColor: !webState.dashboardAvailable
                        ? SkotiqColors.of(context).warning
                        : webState.isRunning
                            ? SkotiqColors.of(context).success
                            : SkotiqColors.of(context).textMuted,
                    label: l10n.text('remoteAccessDashboard'),
                    value: !webState.dashboardAvailable
                        ? l10n.text('remoteAccessDashboardMissing')
                        : webState.isRunning
                            ? l10n.text('remoteAccessDashboardServing')
                            : l10n.text('remoteAccessDashboardIdle'),
                  ),
                  // Active clients and co-imaging participants are different
                  // populations and need separate rows.
                  _StatusRow(
                    icon: LucideIcons.users,
                    iconColor: webState.connectedClients > 0
                        ? SkotiqColors.of(context).primary
                        : SkotiqColors.of(context).textMuted,
                    label: l10n.text('remoteAccessActiveViewers'),
                    value: webState.connectedClients.toString(),
                  ),
                  _StatusRow(
                    icon: LucideIcons.users,
                    iconColor: webState.activeViewers > 0
                        ? SkotiqColors.of(context).primary
                        : SkotiqColors.of(context).textMuted,
                    label: 'Co-imaging viewers',
                    value: webState.activeViewers.toString(),
                  ),
                  // The error wraps rather than clips: the port number in it
                  // is the actionable part. The raw text stays copyable.
                  _StatusRow(
                    icon: webState.lastError.isEmpty
                        ? LucideIcons.info
                        : LucideIcons.alertTriangle,
                    iconColor: webState.lastError.isEmpty
                        ? SkotiqColors.of(context).textMuted
                        : SkotiqColors.of(context).error,
                    label: l10n.text('remoteAccessLastError'),
                    value: webState.lastError.isEmpty
                        ? l10n.text('remoteAccessNoErrors')
                        : explainRemoteAccessError(
                            webState.lastError,
                            webState.configuredPort,
                          ),
                    copyValue:
                        webState.lastError.isEmpty ? null : webState.lastError,
                    valueMaxLines: webState.lastError.isEmpty ? 2 : 6,
                  ),
                ],
              ),
          ],
        );
      },
    );
  }
}
