import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'constellation_format.dart';
import 'constellation_ui_providers.dart';

/// Open the Constellation sign-in flow (adaptive: dialog on desktop/tablet,
/// bottom sheet on phone). Resolves `true` when the user is signed in.
Future<bool?> showConstellationSignInSheet(BuildContext context) {
  return showAdaptiveModal<bool>(
    context: context,
    designWidth: 520,
    builder: (_) => const _ConstellationSignInSheet(),
  );
}

/// Account / login for a self-hosted Constellation hub. Registers an account on
/// the hub (open-signup or bootstrap-token) and persists the issued bearer token
/// + hub URL as the standing credentials. No central Skotiq account exists.
class _ConstellationSignInSheet extends ConsumerStatefulWidget {
  const _ConstellationSignInSheet();

  @override
  ConsumerState<_ConstellationSignInSheet> createState() =>
      _ConstellationSignInSheetState();
}

class _ConstellationSignInSheetState
    extends ConsumerState<_ConstellationSignInSheet> {
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  final _bootstrapController = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    _bootstrapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    // Surface, not SkotiqDialog: showAdaptiveModal already supplies the
    // frame (a Dialog on desktop, a bottom sheet on a phone). Nesting a second
    // dialog stretched that frame into a full-height slab.
    return SkotiqDialogSurface(
      title: 'Connect to a hub',
      icon: LucideIcons.radioTower,
      showCloseButton: !_busy,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
        ),
        SkotiqButton(
          label: 'Connect',
          icon: LucideIcons.logIn,
          isLoading: _busy,
          onPressed: _busy ? null : _connect,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Sign in to a Constellation hub you or your group self-hosts. '
            'Your photons stay yours — nothing is shared until you contribute a '
            'target, and even then only the additive co-add sums by default.',
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          SkotiqTextField(
            controller: _urlController,
            label: 'Hub address',
            hint: 'http://skotiq.local:8090',
            prefixIcon: LucideIcons.link,
            keyboardType: TextInputType.url,
            enabled: !_busy,
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqTextField(
            controller: _nameController,
            label: 'Display name',
            hint: 'How the swarm sees you',
            prefixIcon: LucideIcons.userCircle2,
            enabled: !_busy,
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SkotiqTextField(
            controller: _bootstrapController,
            label: 'Invite token (optional)',
            hint: 'Leave blank for open-signup hubs',
            prefixIcon: LucideIcons.key,
            enabled: !_busy,
          ),
          if (_error != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqBanner(title: _error!, tone: BannerTone.error),
          ],
        ],
      ),
    );
  }

  Future<void> _connect() async {
    final rawUrl = _urlController.text.trim();
    final name = _nameController.text.trim();
    final parsed = Uri.tryParse(rawUrl);
    if (rawUrl.isEmpty || parsed == null || !parsed.hasScheme) {
      setState(() => _error = 'Enter a valid hub address (including http://).');
      return;
    }
    if (name.isEmpty) {
      setState(() => _error = 'Choose a display name.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final settings = ref.read(settingsDaoProvider);
    try {
      final publicKey = await _ensurePublicKey(settings);
      final service = ref.read(constellationServiceProvider);
      final account = await service.registerAccount(
        hubBaseUrl: parsed,
        publicKey: publicKey,
        displayName: name,
        bootstrapToken: _bootstrapController.text.trim(),
      );

      // Persist the standing credentials + identity so the providers resolve.
      // These values form one usable account identity. A partial write could
      // leave the app "configured" with a token but no matching hub/account,
      // so commit the tuple in one database transaction.
      await settings.setSettings({
        constellationHubUrlSettingKey: rawUrl,
        constellationHubTokenSettingKey: account.bearerToken,
        constellationDisplayNameSettingKey: name,
        // Record the hub-issued account id so follow-the-night can tell when
        // the baton's holder is this user (enables the Release affordance).
        constellationAccountIdSettingKey: account.accountId,
      });

      if (!mounted) return;
      ref.invalidate(constellationConfiguredProvider);
      ref.invalidate(constellationHubInfoProvider);
      ref.invalidate(constellationDisplayNameProvider);
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeConstellationError(error);
      });
    }
  }

  /// Mint (once) and return the per-install opaque public key the hub records
  /// against the account. The self-hosted hub only needs a stable identifier,
  /// so a persisted random hex string suffices.
  Future<String> _ensurePublicKey(SettingsDao settings) async {
    final existing = await settings.getSetting(
      constellationPublicKeySettingKey,
    );
    if (existing != null && existing.isNotEmpty) return existing;
    final rng = math.Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    final key = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await settings.setSetting(constellationPublicKeySettingKey, key);
    return key;
  }
}
