// The persisted consent that gates a mosaic panel-master upload.
//
// A panel master is FULL-RESOLUTION integrated data — at least as revealing as
// the raw subframes the Constellation contribute flow gates with its strongest
// consent. So a panel master must NEVER leave the device under a silent
// hardcoded license: the user has to pick a sharing license + an attribution
// (anonymity) preference, and explicitly opt in, exactly like
// `constellation_contribute_sheet.dart`.
//
// The interactive UI presents that choice and persists it here; an UNATTENDED
// rig (the [CollaborativeMosaicPoller] auto-uploading on a "nobody watching"
// night, or the headless REST upload endpoint) has no sheet to present, so it
// reads this PERSISTED record instead. A missing record means the user has not
// consented and the upload is refused — fail closed, never a default ccBy.

import '../../database/daos/settings_dao.dart';
import '../../models/collaboration/collaboration_models.dart'
    show ContributionLicense;

/// Settings key the "user has explicitly consented to mosaic uploads" flag
/// persists under (`'1'` once granted in the contribute sheet).
const String mosaicUploadConsentedSettingKey = 'mosaic.upload.consented';

/// Settings key the chosen mosaic-upload sharing license persists under (the
/// [ContributionLicense.wireName]).
const String mosaicUploadLicenseSettingKey = 'mosaic.upload.license';

/// Settings key the attribution (credit-me) choice persists under (`'1'` to be
/// credited by display name, `'0'` to be listed as an anonymous contributor).
const String mosaicUploadAttributionSettingKey = 'mosaic.upload.attribution';

/// Settings key the "allow an unattended rig to auto-upload my integrated
/// panels" opt-in persists under (`'1'` to let the poller ship panels with
/// nobody watching, `'0'` to keep uploads manual). Default off.
const String mosaicUploadAutoSettingKey = 'mosaic.upload.auto';

/// The recorded consent under which this rig's integrated mosaic panel masters
/// may leave the device: the sharing [license], whether the contributor wants
/// public [attributionConsent] credit (vs anonymous), and whether the rig may
/// [autoUpload] panels unattended.
///
/// This is only ever constructed for a consent the user ACTUALLY granted — the
/// resolver returns null (not a permissive default) when no consent is on
/// record, so every caller fails closed on absence.
class MosaicUploadConsent {
  const MosaicUploadConsent({
    required this.license,
    required this.attributionConsent,
    this.autoUpload = false,
  });

  /// The sharing license the panel master is uploaded under. Always a
  /// shareable license (the resolver rejects a non-shareable record).
  final ContributionLicense license;

  /// Whether the contributor consents to public, name-credited attribution.
  /// When false the hub records the contribution as an anonymous contributor.
  final bool attributionConsent;

  /// Whether an unattended rig may auto-upload this rig's integrated panels
  /// without a human present (the [CollaborativeMosaicPoller] gate).
  final bool autoUpload;

  MosaicUploadConsent copyWith({
    ContributionLicense? license,
    bool? attributionConsent,
    bool? autoUpload,
  }) {
    return MosaicUploadConsent(
      license: license ?? this.license,
      attributionConsent: attributionConsent ?? this.attributionConsent,
      autoUpload: autoUpload ?? this.autoUpload,
    );
  }
}

/// Resolve the persisted mosaic-upload consent, or null when the user has not
/// granted it. Fails CLOSED: a missing consent flag, or a stored license that
/// is not shareable (e.g. a corrupt `private`), yields null so the upload is
/// refused rather than defaulting to a silent ccBy + forced attribution.
Future<MosaicUploadConsent?> resolveMosaicUploadConsent(
  SettingsDao settings,
) async {
  final consented = await settings.getSetting(mosaicUploadConsentedSettingKey);
  if (consented != '1') return null;
  final licenseWire = await settings.getSetting(mosaicUploadLicenseSettingKey);
  final license = ContributionLicense.fromWire(
    licenseWire,
    fallback: ContributionLicense.private,
  );
  // A non-shareable license is not a valid upload consent — fail closed.
  if (!license.isShareable) return null;
  final attribution = await settings.getSetting(
    mosaicUploadAttributionSettingKey,
  );
  final auto = await settings.getSetting(mosaicUploadAutoSettingKey);
  return MosaicUploadConsent(
    license: license,
    // Default to credited only when never set; an explicit '0' anonymizes.
    attributionConsent: attribution == null ? true : attribution == '1',
    autoUpload: auto == '1',
  );
}

/// Persist the user's mosaic-upload [consent] (granted in the contribute sheet)
/// so the unattended poller + headless upload endpoint can honor the same
/// license + anonymity + auto-upload choice the interactive UI captured.
Future<void> persistMosaicUploadConsent(
  SettingsDao settings,
  MosaicUploadConsent consent,
) async {
  await settings.setSettings({
    mosaicUploadConsentedSettingKey: '1',
    mosaicUploadLicenseSettingKey: consent.license.wireName,
    mosaicUploadAttributionSettingKey: consent.attributionConsent ? '1' : '0',
    mosaicUploadAutoSettingKey: consent.autoUpload ? '1' : '0',
  });
}
