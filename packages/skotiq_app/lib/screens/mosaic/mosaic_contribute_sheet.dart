import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../constellation/constellation_ui_providers.dart'
    show constellationHubInfoProvider;

/// The per-upload consent the contribute sheet resolves: the sharing [license]
/// and whether the contributor wants name-credited [attributionConsent].
typedef MosaicUploadConsentChoice = ({
  ContributionLicense license,
  bool attributionConsent,
});

/// What a collaborative contribution consent sheet gates — selects the wording
/// for the kind of data that leaves the device. Both variants persist to (and
/// read from) the SAME [MosaicUploadConsent] record, so a rig honours ONE
/// consent contract (license + attribution + unattended auto-upload) across
/// mosaic panel masters and live co-imaging subs: granting it from
/// either entry point enables the other, and the unattended auto-upload opt-in
/// gates both the poller and the co-imaging auto-contribute egress.
enum CollaborativeContributeContext {
  /// A full-resolution integrated mosaic panel master.
  mosaicPanel,

  /// This rig's live co-imaging subs folding into a shared target.
  coImagingSubs,
}

/// The persisted mosaic-upload consent, seeded into the contribute sheet so a
/// repeat upload pre-fills the user's last license + anonymity + auto choice.
final mosaicUploadConsentProvider =
    FutureProvider<MosaicUploadConsent?>((ref) async {
  return resolveMosaicUploadConsent(ref.watch(settingsDaoProvider));
});

/// Present the consent contract for a collaborative contribution and return the
/// chosen [MosaicUploadConsentChoice], or null if the user cancelled.
///
/// A panel master is full-resolution integrated data — and a co-imaging sub is
/// raw pixels — so, exactly like the Constellation contribute flow, the user
/// must explicitly pick a sharing license (constrained to the hub's advertised
/// set), choose whether to be credited or stay anonymous, and opt in before any
/// pixels leave the device. The choice (including the unattended auto-upload
/// opt-in that gates both the poller and the co-imaging auto-contribute egress)
/// is persisted so the headless endpoints + the unattended paths honor the same
/// contract. [purpose] selects the wording for what data is being shared; both
/// variants persist to the SAME [MosaicUploadConsent] record.
Future<MosaicUploadConsentChoice?> showMosaicContributeSheet(
  BuildContext context, {
  CollaborativeContributeContext purpose =
      CollaborativeContributeContext.mosaicPanel,
}) {
  return showAdaptiveModal<MosaicUploadConsentChoice>(
    context: context,
    designWidth: 560,
    phoneMode: PhoneModalMode.bottomSheet,
    builder: (_) => _MosaicContributeSheet(purpose: purpose),
  );
}

/// Explicit license + anonymity + consent choice before full-resolution
/// collaborative data leaves the device.
class _MosaicContributeSheet extends ConsumerStatefulWidget {
  const _MosaicContributeSheet({required this.purpose});

  /// Selects the wording for what data this contribution shares (a mosaic panel
  /// master vs live co-imaging subs). Both persist the same consent record.
  final CollaborativeContributeContext purpose;

  @override
  ConsumerState<_MosaicContributeSheet> createState() =>
      _MosaicContributeSheetState();
}

class _MosaicContributeSheetState
    extends ConsumerState<_MosaicContributeSheet> {
  /// The license the panel master is shared under (default attribution-required
  /// CC-BY, constrained to the hub's advertised set in [build]).
  ContributionLicense _license = ContributionLicense.ccBy;

  /// Whether the contributor wants public credit. When false the hub records an
  /// "Anonymous contributor" attribution.
  bool _creditMe = true;

  /// Whether this rig may auto-upload integrated panels unattended (the poller
  /// gate). Off by default — unattended sharing is a deliberate opt-in.
  bool _autoUpload = false;

  /// Explicit per-upload consent gate — the panel master only ships once this
  /// is checked.
  bool _consented = false;
  bool _busy = false;
  String? _error;
  bool _loadedChoice = false;

  CollaborativeContributeContext get _purpose => widget.purpose;

  /// Dialog title for the contribution being consented to.
  String get _title => switch (_purpose) {
        CollaborativeContributeContext.mosaicPanel => 'Share this panel master',
        CollaborativeContributeContext.coImagingSubs =>
          'Share your co-imaging subs',
      };

  /// Intro copy explaining what data leaves the device and why.
  String get _intro => switch (_purpose) {
        CollaborativeContributeContext.mosaicPanel =>
          'Uploading sends this panel\'s full-resolution integrated master to '
              'the hub so your club can assemble the finished mosaic. Choose how '
              'it may be used and credited before it leaves your device.',
        CollaborativeContributeContext.coImagingSubs =>
          'Contributing folds each completed sub into the shared target\'s '
              'combined stack on the hub so every rig\'s integration adds up. '
              'Choose how your data may be used and credited before anything '
              'leaves your device.',
      };

  /// Copy for the unattended auto-upload / auto-contribute opt-in.
  String get _autoUploadLabel => switch (_purpose) {
        CollaborativeContributeContext.mosaicPanel =>
          'Let this rig auto-upload my integrated panels unattended (needed for '
              'a hands-off collaborative night). Leave unchecked to keep every '
              'upload manual.',
        CollaborativeContributeContext.coImagingSubs =>
          'Let this rig contribute my completed subs unattended (needed for '
              'them to co-add during a hands-off co-imaging night). Leave '
              'unchecked and your subs will NOT be added to the combined stack.',
      };

  /// Copy for the explicit per-contribution consent checkbox.
  String get _consentLabel => switch (_purpose) {
        CollaborativeContributeContext.mosaicPanel =>
          'I understand this uploads my full-resolution panel master under the '
              'license above and consent to sharing it with this hub.',
        CollaborativeContributeContext.coImagingSubs =>
          'I understand this shares my completed subs under the license above '
              'and consent to co-adding them into this hub\'s combined stack.',
      };

  /// Confirm-button label ("Upload" for a one-shot mosaic panel, "Enable
  /// sharing" for the co-imaging opt-in, which persists consent rather than
  /// pushing pixels right now).
  String get _confirmLabel => switch (_purpose) {
        CollaborativeContributeContext.mosaicPanel => 'Upload',
        CollaborativeContributeContext.coImagingSubs => 'Enable sharing',
      };

  /// Adopt the persisted consent the first time it resolves, without clobbering
  /// a choice the user has already made in the sheet.
  void _seedConsent(MosaicUploadConsent? stored) {
    if (_loadedChoice || stored == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_loadedChoice || !mounted) return;
      setState(() {
        _license = stored.license;
        _creditMe = stored.attributionConsent;
        _autoUpload = stored.autoUpload;
        _loadedChoice = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    ref.listen<AsyncValue<MosaicUploadConsent?>>(
      mosaicUploadConsentProvider,
      (_, next) => _seedConsent(next.valueOrNull),
    );
    _seedConsent(ref.watch(mosaicUploadConsentProvider).valueOrNull);

    // The licenses the hub advertises it accepts; offer only those (falling back
    // to the full shareable set for an older hub that does not advertise any).
    final hubInfo = ref.watch(constellationHubInfoProvider);
    final hub = hubInfo.valueOrNull;
    final advertised = hub?.supportedLicenses ?? const <String>[];
    // Empty means "legacy hub" only after HubInfo actually resolves. While
    // loading (or after an error), fail closed so an upload cannot leave under
    // a guessed license just before the host advertises a different set.
    final licenses = hub == null
        ? const <ContributionLicense>[]
        : _shareableLicenses
            .where(
              (license) =>
                  advertised.isEmpty || advertised.contains(license.wireName),
            )
            .toList(growable: false);
    final hasCompatibleLicense = licenses.isNotEmpty;
    final current = licenses.contains(_license)
        ? _license
        : (hasCompatibleLicense ? licenses.first : ContributionLicense.ccBy);

    // Surface, not SkotiqDialog: showAdaptiveModal already supplies the
    // frame (a Dialog on desktop, a bottom sheet on a phone). Nesting a second
    // dialog stretched that frame into a full-height slab.
    return SkotiqDialogSurface(
      title: _title,
      icon: LucideIcons.upload,
      showCloseButton: !_busy,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          label: _confirmLabel,
          icon: LucideIcons.upload,
          isLoading: _busy,
          onPressed: (_consented && hasCompatibleLicense && !_busy)
              ? () => _confirm(current)
              : null,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _intro,
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          Text(
            'License',
            style: SkotiqTypography.label
                .copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          if (hubInfo.isLoading)
            const SkotiqBanner(
              title: 'Checking this hub\'s licenses',
              tone: BannerTone.info,
              message: 'Checking the hub\'s supported sharing licenses…',
            )
          else if (hubInfo.hasError)
            const SkotiqBanner(
              title: 'The hub\'s sharing licenses could not be read',
              tone: BannerTone.error,
              message: 'Could not verify this hub\'s sharing licenses. '
                  'Check the connection and try again.',
            )
          else if (hasCompatibleLicense)
            SkotiqDropdown(
              isExpanded: true,
              value: current.wireName,
              items: licenses.map((l) => l.wireName).toList(growable: false),
              itemLabels: licenses.map(_licenseLabel).toList(growable: false),
              onChanged: _busy
                  ? null
                  : (wire) => setState(() {
                        _license = ContributionLicense.fromWire(
                          wire,
                          fallback: current,
                        );
                        _loadedChoice = true;
                      }),
            )
          else
            const SkotiqBanner(
              title: 'No compatible sharing license',
              tone: BannerTone.error,
              message: 'This hub does not advertise a compatible sharing '
                  'license. Ask its administrator to enable CC BY, CC0, '
                  'CC BY-SA, or CC BY-NC.',
            ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _ConsentRow(
            value: _creditMe,
            label: 'Credit me as a contributor. Uncheck to be listed as an '
                '"Anonymous contributor" on the finished mosaic.',
            onChanged: _busy
                ? null
                : (v) => setState(() {
                      _creditMe = v ?? false;
                      _loadedChoice = true;
                    }),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _ConsentRow(
            value: _autoUpload,
            label: _autoUploadLabel,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                      _autoUpload = v ?? false;
                      _loadedChoice = true;
                    }),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _ConsentRow(
            value: _consented,
            label: _consentLabel,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                      _consented = v ?? false;
                      _loadedChoice = true;
                    }),
          ),
          if (_error != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqBanner(
              title: 'This contribution was refused',
              tone: BannerTone.error,
              message: _error!,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirm(ContributionLicense license) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final consent = MosaicUploadConsent(
      license: license,
      attributionConsent: _creditMe,
      autoUpload: _autoUpload,
    );
    try {
      // Persist so the headless endpoint + unattended poller honor the same
      // license + anonymity + auto choice this sheet captured.
      await persistMosaicUploadConsent(ref.read(settingsDaoProvider), consent);
      if (!mounted) return;
      ref.invalidate(mosaicUploadConsentProvider);
      Navigator.of(context).pop((
        license: consent.license,
        attributionConsent: consent.attributionConsent,
      ));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not save your sharing choice: $error';
      });
    }
  }
}

/// The shareable licenses offered for a panel-master upload, in order of
/// permissiveness. `private` is never offered — uploading into a shared mosaic
/// is inherently a share, so the hub rejects a non-shareable license.
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

class _ConsentRow extends StatelessWidget {
  final bool value;
  final String label;
  final ValueChanged<bool?>? onChanged;

  const _ConsentRow({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Semantics(
        button: true,
        enabled: onChanged != null,
        child: InkWell(
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
                    label,
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ));
  }
}
