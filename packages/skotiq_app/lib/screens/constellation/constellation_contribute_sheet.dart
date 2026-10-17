import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
// Hide the core wire enum of the same name; this screen uses the richer
// app-side `ConstellationPrivacy` from constellation_ui_providers.dart and maps
// to the core one via its `.wire` getter when calling the service.
import 'package:skotiq_core/skotiq_core.dart' hide ConstellationPrivacy;
import 'package:skotiq_ui/skotiq_ui.dart';

import 'constellation_format.dart';
import 'constellation_ui_providers.dart';

/// Open the contribute consent flow for [target]. Resolves the
/// [ContributionOutcome] once the push completes, or null if the user cancelled.
Future<ContributionOutcome?> showConstellationContributeSheet(
  BuildContext context, {
  required SharedTarget target,
}) {
  return showAdaptiveModal<ContributionOutcome>(
    context: context,
    designWidth: 560,
    phoneMode: PhoneModalMode.bottomSheet,
    builder: (_) => _ConstellationContributeSheet(target: target),
  );
}

/// Explicit consent + privacy choice before any pixels leave the device.
///
/// The default and recommended choice is SUMS — only the additive co-add stack
/// the master integration already keeps. SUBS (raw subframes) is the heavier,
/// more-revealing opt-in. The choice is persisted; the upload itself ships the
/// additive `.nst` sums through [ConstellationService.contributeTarget].
class _ConstellationContributeSheet extends ConsumerStatefulWidget {
  final SharedTarget target;

  const _ConstellationContributeSheet({required this.target});

  @override
  ConsumerState<_ConstellationContributeSheet> createState() =>
      _ConstellationContributeSheetState();
}

class _ConstellationContributeSheetState
    extends ConsumerState<_ConstellationContributeSheet> {
  ConstellationPrivacy _privacy = ConstellationPrivacy.sums;
  bool _consented = false;

  /// The license the user shares this contribution under.
  /// The hub requires an explicit shareable license + records consent before any
  /// bytes are stored; the client pre-validates this against the hub's
  /// advertised `supportedLicenses`. Defaults to the attribution-required CC-BY.
  ContributionLicense _license = ContributionLicense.ccBy;

  /// Whether the contributor wants public credit. When false the hub records the
  /// contribution as an "Anonymous contributor" in the artifact's attribution.
  bool _creditMe = true;

  /// Second, stronger consent required ONLY for SUBS: raw subframes reveal far
  /// more than additive sums and cannot be cleanly un-shared.
  bool _rawSubsConsented = false;
  bool _busy = false;
  String? _error;
  bool _loadedChoice = false;

  /// Adopt the persisted privacy preference the first time it resolves, without
  /// clobbering a choice the user has already made in the sheet. Mutation is
  /// deferred to after the frame so it is never run during build.
  void _seedPrivacy(ConstellationPrivacy? stored) {
    if (_loadedChoice || stored == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_loadedChoice || !mounted) return;
      setState(() {
        _privacy = stored;
        _loadedChoice = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    // Seed the privacy toggle from the persisted preference once — the provider
    // is watched unconditionally and the mutation is deferred out of build.
    ref.listen<AsyncValue<ConstellationPrivacy>>(
      constellationPrivacyProvider,
      (_, next) => _seedPrivacy(next.valueOrNull),
    );
    _seedPrivacy(ref.watch(constellationPrivacyProvider).valueOrNull);

    // Whether THIS hub accepts raw subframes. When it doesn't (the default, and
    // for any older hub), the SUBS option is rendered disabled with an
    // explanation rather than letting the user consent and only then error.
    final hubInfo = ref.watch(constellationHubInfoProvider);
    final hub = hubInfo.valueOrNull;
    final acceptsRawSubs = hub?.acceptsRawSubs ?? false;
    final advertisedLicenses = hub?.supportedLicenses ?? const <String>[];
    // An empty list is a legitimate legacy-hub response, but `hub == null`
    // also represents loading/error. Only the former may use the compatibility
    // fallback; capability discovery must finish before sharing is enabled.
    final licenses = hub == null
        ? const <ContributionLicense>[]
        : _shareableLicenses
            .where(
              (license) =>
                  advertisedLicenses.isEmpty ||
                  advertisedLicenses.contains(license.wireName),
            )
            .toList(growable: false);
    final hasCompatibleLicense = licenses.isNotEmpty;
    final effectiveLicense = licenses.contains(_license)
        ? _license
        : (hasCompatibleLicense ? licenses.first : ContributionLicense.ccBy);
    // A persisted SUBS preference on a hub that no longer accepts raw subframes
    // must not leave the disabled option silently selected — coerce to sums.
    final subsSelected =
        _privacy == ConstellationPrivacy.subs && acceptsRawSubs;
    // SUBS needs BOTH the base consent and the stronger raw-subs consent.
    final canContribute = _consented &&
        (!subsSelected || _rawSubsConsented) &&
        hasCompatibleLicense &&
        !_busy;

    // Surface, not SkotiqDialog: showAdaptiveModal already supplies the
    // frame (a Dialog on desktop, a bottom sheet on a phone). Nesting a second
    // dialog stretched that frame into a full-height slab.
    return SkotiqDialogSurface(
      title: 'Contribute to the swarm',
      icon: LucideIcons.upload,
      showCloseButton: !_busy,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          label: 'Contribute',
          icon: LucideIcons.upload,
          isLoading: _busy,
          onPressed: canContribute ? () => _contribute(effectiveLicense) : null,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'You are about to add your imaging of '
            '"${widget.target.name.isEmpty ? 'target #${widget.target.targetId}' : widget.target.name}" '
            'to the shared co-add. Choose what leaves your device.',
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          for (final option in ConstellationPrivacy.values) ...[
            Builder(
              builder: (_) {
                // SUBS is selectable only on a hub that accepts raw subframes.
                final isSubs = option == ConstellationPrivacy.subs;
                final disabled = isSubs && !acceptsRawSubs;
                return _PrivacyOption(
                  option: option,
                  selected: _privacy == option,
                  disabled: disabled,
                  disabledNote: disabled
                      ? 'This hub does not accept raw subframes.'
                      : null,
                  onSelect: (_busy || disabled)
                      ? null
                      : () => setState(() {
                            _privacy = option;
                            _loadedChoice = true;
                          }),
                );
              },
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
          ],
          const SizedBox(height: SkotiqTokens.spaceSm),
          // The reassurance banner is true ONLY for sums; showing it under a
          // SUBS selection would contradict the choice, so it is conditional.
          if (!subsSelected)
            const SkotiqBanner(
                title: 'You only share additive co-add sums, so a contribution '
                    'can be subtracted exactly hub-side — the shared depth returns '
                    'to what it was before.',
                tone: BannerTone.info)
          else
            const SkotiqBanner(
                title:
                    'Raw subframes reveal your exact pixels and pointing and '
                    'cannot be subtracted as cleanly as sums — anyone with read '
                    'access can download them. Removing one later is a file '
                    'delete, not a clean subtraction.',
                tone: BannerTone.warning),
          const SizedBox(height: SkotiqTokens.spaceMd),
          // Consent contract: choose the license this contribution is shared
          // under. The hub advertises the licenses it accepts; offer only those
          // (falling back to the full shareable set for an older hub). The hub
          // re-validates and records the consent before storing any bytes.
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'License',
                style: SkotiqTypography.label.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceXs),
              if (hubInfo.isLoading)
                const SkotiqBanner(
                    title: 'Checking the hub\'s supported sharing licenses…',
                    tone: BannerTone.info)
              else if (hubInfo.hasError)
                const SkotiqBanner(
                    title: 'Could not verify this hub\'s sharing licenses. '
                        'Check the connection and try again.',
                    tone: BannerTone.error)
              else if (hasCompatibleLicense)
                SkotiqDropdown(
                  isExpanded: true,
                  value: effectiveLicense.wireName,
                  items: licenses
                      .map((license) => license.wireName)
                      .toList(growable: false),
                  itemLabels:
                      licenses.map(_licenseLabel).toList(growable: false),
                  onChanged: _busy
                      ? null
                      : (wire) => setState(() {
                            _license = ContributionLicense.fromWire(
                              wire,
                              fallback: effectiveLicense,
                            );
                            // Any interaction takes ownership of the sheet so a
                            // late-resolving persisted privacy preference can no
                            // longer overwrite the represented sharing choice.
                            _loadedChoice = true;
                          }),
                )
              else
                const SkotiqBanner(
                    title: 'This hub does not advertise a compatible sharing '
                        'license. Ask its administrator to enable CC BY, CC0, '
                        'CC BY-SA, or CC BY-NC.',
                    tone: BannerTone.error),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _ConsentRow(
            value: _creditMe,
            label: 'Credit me as a contributor. Uncheck to be listed as an '
                '"Anonymous contributor" in the finished artifact.',
            onChanged: _busy
                ? null
                : (v) => setState(() {
                      _creditMe = v ?? false;
                      _loadedChoice = true;
                    }),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _ConsentRow(
            value: _consented,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                      _consented = v ?? false;
                      _loadedChoice = true;
                    }),
          ),
          // Second, stronger consent gate shown only for the SUBS choice.
          if (subsSelected) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            _ConsentRow(
              value: _rawSubsConsented,
              label: 'I understand raw subframes expose my exact pixels and '
                  'pointing, can be downloaded by anyone with read access, and '
                  'cannot be cleanly un-shared.',
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                        _rawSubsConsented = v ?? false;
                        _loadedChoice = true;
                      }),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqBanner(title: _error!, tone: BannerTone.error),
          ],
        ],
      ),
    );
  }

  Future<void> _contribute(ContributionLicense license) async {
    // Only ship SUBS if the hub actually accepts it AND the stronger consent was
    // given; otherwise fall back to sums (belt-and-suspenders for the gating in
    // build, so a stale `_privacy` can never leak raw pixels).
    final acceptsRawSubs =
        ref.read(constellationHubInfoProvider).valueOrNull?.acceptsRawSubs ??
            false;
    final effective = (_privacy == ConstellationPrivacy.subs &&
            acceptsRawSubs &&
            _rawSubsConsented)
        ? ConstellationPrivacy.subs
        : ConstellationPrivacy.sums;
    setState(() {
      _busy = true;
      _error = null;
    });
    final settings = ref.read(settingsDaoProvider);
    try {
      await settings.setSetting(
        constellationPrivacySettingKey,
        effective.name,
      );
      final outcome =
          await ref.read(constellationServiceProvider).contributeTarget(
                widget.target.targetId,
                radiusDeg: widget.target.radiusDeg,
                privacy: effective.wire,
                license: license,
                attributionConsent: _creditMe,
              );
      if (!mounted) return;
      ref.invalidate(constellationPrivacyProvider);
      Navigator.of(context).pop(outcome);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeConstellationError(error);
      });
    }
  }
}

/// The shareable licenses offered in the contribute sheet, in order of
/// permissiveness. `private` is never offered — a contribution into the shared
/// co-add is inherently a share, so the hub rejects a non-shareable license.
const List<ContributionLicense> _shareableLicenses = <ContributionLicense>[
  ContributionLicense.ccBy,
  ContributionLicense.ccBySa,
  ContributionLicense.ccByNc,
  ContributionLicense.cc0,
];

/// Human-readable label for a license choice in the dropdown.
String _licenseLabel(ContributionLicense license) {
  switch (license) {
    case ContributionLicense.cc0:
      return 'CC0 — public domain (no attribution required)';
    case ContributionLicense.ccBy:
      return 'CC BY — credit required, any use';
    case ContributionLicense.ccBySa:
      return 'CC BY-SA — credit + share-alike';
    case ContributionLicense.ccByNc:
      return 'CC BY-NC — credit, non-commercial only';
    case ContributionLicense.private:
      return 'Private — not shared';
  }
}

class _PrivacyOption extends StatelessWidget {
  final ConstellationPrivacy option;
  final bool selected;
  final bool disabled;
  final String? disabledNote;
  final VoidCallback? onSelect;

  const _PrivacyOption({
    required this.option,
    required this.selected,
    required this.onSelect,
    this.disabled = false,
    this.disabledNote,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final recommended = option == ConstellationPrivacy.sums;
    final titleColor = disabled ? colors.textMuted : colors.textPrimary;
    final blurbColor = disabled ? colors.textMuted : colors.textSecondary;
    return Opacity(
      opacity: disabled ? 0.6 : 1.0,
      child: SkotiqCard(
        variant: selected ? CardVariant.elevated : CardVariant.subtle,
        isSelected: selected,
        onTap: onSelect,
        padding: SkotiqTokens.cardPadding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? LucideIcons.checkCircle2 : LucideIcons.circle,
              size: SkotiqTokens.iconMd,
              color: selected ? colors.accent : colors.textMuted,
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          option.label,
                          style: SkotiqTypography.labelStrong.copyWith(
                            color: titleColor,
                          ),
                        ),
                      ),
                      if (recommended) ...[
                        const SizedBox(width: SkotiqTokens.spaceSm),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: SkotiqTokens.spaceSm,
                            vertical: 2,
                          ),
                          decoration: SkotiqDecorations.chip(colors,
                              tone: colors.success),
                          child: Text(
                            'DEFAULT',
                            style: SkotiqTypography.captionSm.copyWith(
                              color: colors.success,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: SkotiqTokens.spaceXs),
                  Text(
                    option.blurb,
                    style: SkotiqTypography.captionSm.copyWith(
                      color: blurbColor,
                      height: 1.4,
                    ),
                  ),
                  if (disabled && disabledNote != null) ...[
                    const SizedBox(height: SkotiqTokens.spaceXs),
                    Text(
                      disabledNote!,
                      style: SkotiqTypography.captionSm.copyWith(
                        color: colors.warning,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConsentRow extends StatelessWidget {
  final bool value;
  final String? label;
  final ValueChanged<bool?>? onChanged;

  const _ConsentRow({
    required this.value,
    required this.onChanged,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
      child: Padding(
        padding: const EdgeInsets.all(SkotiqTokens.spaceXs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkotiqCheckbox(value: value, onChanged: onChanged),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: Text(
                label ??
                    'I understand what is being shared and consent to '
                        'contributing it to this self-hosted hub.',
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
