import '../../providers/framing_provider.dart' show SurveySource;

/// One registered HiPS survey: how to reach its tile pyramid on a CDS mirror.
///
/// This binds a framing [SurveySource] (the user-facing survey choice already
/// driving the single-cutout background) to the CDS HiPS metadata it is served
/// from, so the tile layer streams the *same* survey the snapshot path uses —
/// the HiPS tiles and the existing single image agree pixel-for-pixel in
/// content, only differing in delivery (zoomable pyramid vs. one cutout).
///
/// [hipsId] is the canonical CDS HiPS identifier (e.g. `CDS/P/DSS2/red`) — the
/// exact id the existing [SurveySource] -> HiPS-id mapping in the framing
/// provider passes to the hips2fits cutout service, kept identical here so the
/// two code paths never diverge.
///
/// [baseUrl] is the root the tile/`properties`/Allsky paths are appended to.
/// For surveys whose direct tile mirror is **live-verified** it is non-null and
/// addresses the survey's pyramid directly. For the rest it is `null`: per the
/// component contract there is *no fetch logic here* and *no guessed URL* — the
/// concrete base must be resolved at runtime from the CDS HiPS registry +
/// `properties` document (errors surface there if resolution fails, never a
/// silently fabricated URL).
class HipsSurveyEntry {
  /// The framing survey this entry corresponds to.
  final SurveySource source;

  /// Canonical CDS HiPS identifier, identical to the id used by the framing
  /// hips2fits cutout path.
  final String hipsId;

  /// Direct tile-pyramid base URL when live-verified, else `null` (resolve at
  /// runtime — never fabricate).
  final String? baseUrl;

  /// Whether [baseUrl] has been live-verified against the published pyramid.
  final bool baseUrlVerified;

  /// The survey's publisher acknowledgement, as a STATIC string.
  ///
  /// Attribution is a licence obligation attached to the IMAGERY, so it must
  /// not depend on a `properties` fetch succeeding: a survey whose pyramid is
  /// resolved at runtime fetches no `properties` document at all, while its
  /// imagery still streams through the hips2fits cutout path.
  ///
  /// A live `properties` document's `obs_copyright` (when one is resolved) is
  /// the more current source and takes precedence; this is the floor that
  /// guarantees a credit is always available offline.
  final String attributionCredit;

  /// Canonical attribution / copyright page for [attributionCredit], or null
  /// when the publisher does not host one.
  final String? attributionUrl;

  const HipsSurveyEntry({
    required this.source,
    required this.hipsId,
    required this.baseUrl,
    required this.baseUrlVerified,
    required this.attributionCredit,
    this.attributionUrl,
  });

  /// True when [baseUrl] is known and verified and can be used directly.
  bool get hasVerifiedBaseUrl => baseUrlVerified && baseUrl != null;

  @override
  String toString() =>
      'HipsSurveyEntry($source -> $hipsId, '
      'baseUrl=${baseUrl ?? "<resolve-at-runtime>"}, '
      'verified=$baseUrlVerified)';
}

/// Registry mapping every framing [SurveySource] to its CDS HiPS survey.
///
/// This is a static, pure-Dart lookup table — the single source of truth the
/// tile layer consults to learn which HiPS pyramid a survey selection maps to.
/// It performs **no network I/O**: verified base URLs are baked in; unverified
/// surveys expose only their canonical [HipsSurveyEntry.hipsId] for a runtime
/// resolver to turn into a base URL (which is why those entries' `baseUrl` is
/// `null` rather than a plausible-looking guess).
///
/// The CDS mirror root used for the verified entries is the public hips.cds
/// distribution host. DSS2 colour and DSS2 red are the two live-verified
/// pyramids; their base URLs were confirmed to serve a valid `properties`
/// document and an `Allsky` map at the advertised orders.
class HipsSurveyRegistry {
  HipsSurveyRegistry._();

  /// Public CDS HiPS distribution host the verified pyramids live under.
  ///
  /// Exposed so a runtime resolver can build candidate base URLs for the
  /// unverified surveys from their [HipsSurveyEntry.hipsId] consistently with
  /// the verified ones, rather than hard-coding the host in two places.
  static const String cdsHost = 'https://alasky.cds.unistra.fr';

  /// All registered surveys keyed by [SurveySource].
  ///
  /// Every [SurveySource] is present; this is asserted by
  /// [debugAssertExhaustive] and the registry test so adding a new survey
  /// without an entry fails loudly rather than producing a silent gap.
  /// The DSS acknowledgement STScI requires with any DSS-derived image.
  static const String _dssCredit =
      'Digitized Sky Survey - STScI/NASA, Healpixed by CDS';
  static const String _dssCreditUrl =
      'http://archive.stsci.edu/dss/copyright.html';

  /// The 2MASS acknowledgement (all three bands share one publisher set).
  static const String _twomassCredit =
      'Two Micron All Sky Survey (2MASS) - University of Massachusetts and '
      'IPAC/Caltech, funded by NASA and NSF, Healpixed by CDS';
  static const String _twomassCreditUrl =
      'https://irsa.ipac.caltech.edu/Missions/2mass.html';

  static const Map<SurveySource, HipsSurveyEntry> entries = {
    // DSS2 red — live-verified direct pyramid (the framing default source).
    SurveySource.dss2Red: HipsSurveyEntry(
      source: SurveySource.dss2Red,
      hipsId: 'CDS/P/DSS2/red',
      baseUrl: '$cdsHost/DSS/DSS2Merged',
      baseUrlVerified: true,
      attributionCredit: _dssCredit,
      attributionUrl: _dssCreditUrl,
    ),
    // DSS2 blue — live-verified direct pyramid. Together with DSS2 red
    // (DSS2Merged) this is one of the two mono DSS2 pyramids CDS publishes and
    // composes into its DSS2 colour map; its `properties`/Allsky were confirmed
    // live at order 9.
    SurveySource.dss2Blue: HipsSurveyEntry(
      source: SurveySource.dss2Blue,
      hipsId: 'CDS/P/DSS2/blue',
      baseUrl: '$cdsHost/DSS/DSS2-blue-XJ-S',
      baseUrlVerified: true,
      attributionCredit: _dssCredit,
      attributionUrl: _dssCreditUrl,
    ),
    // Remaining surveys: canonical hips id only; base URL resolved at runtime
    // from the CDS registry + properties (never fabricated here). Their
    // attribution is still baked in — their imagery reaches the screen via the
    // hips2fits cutout path whether or not a pyramid is ever resolved, and the
    // publishers' acknowledgement requirements apply to that imagery too.
    SurveySource.dss2IR: HipsSurveyEntry(
      source: SurveySource.dss2IR,
      hipsId: 'CDS/P/DSS2/NIR',
      baseUrl: null,
      baseUrlVerified: false,
      attributionCredit: _dssCredit,
      attributionUrl: _dssCreditUrl,
    ),
    SurveySource.sdss: HipsSurveyEntry(
      source: SurveySource.sdss,
      hipsId: 'CDS/P/SDSS9/color',
      baseUrl: null,
      baseUrlVerified: false,
      attributionCredit:
          'Sloan Digital Sky Survey (SDSS DR9), Healpixed by CDS',
      attributionUrl: 'https://www.sdss.org/collaboration/citing-sdss/',
    ),
    SurveySource.twomassJ: HipsSurveyEntry(
      source: SurveySource.twomassJ,
      hipsId: 'CDS/P/2MASS/J',
      baseUrl: null,
      baseUrlVerified: false,
      attributionCredit: _twomassCredit,
      attributionUrl: _twomassCreditUrl,
    ),
    SurveySource.twomassH: HipsSurveyEntry(
      source: SurveySource.twomassH,
      hipsId: 'CDS/P/2MASS/H',
      baseUrl: null,
      baseUrlVerified: false,
      attributionCredit: _twomassCredit,
      attributionUrl: _twomassCreditUrl,
    ),
    SurveySource.twomassK: HipsSurveyEntry(
      source: SurveySource.twomassK,
      hipsId: 'CDS/P/2MASS/K',
      baseUrl: null,
      baseUrlVerified: false,
      attributionCredit: _twomassCredit,
      attributionUrl: _twomassCreditUrl,
    ),
    SurveySource.wise12: HipsSurveyEntry(
      source: SurveySource.wise12,
      hipsId: 'CDS/P/WISE/W3',
      baseUrl: null,
      baseUrlVerified: false,
      attributionCredit: 'WISE - NASA/JPL-Caltech/UCLA, Healpixed by CDS',
      attributionUrl: 'https://irsa.ipac.caltech.edu/Missions/wise.html',
    ),
  };

  /// Returns the registry entry for [source].
  ///
  /// Throws [StateError] if no entry exists — a missing mapping is a
  /// programming error (a [SurveySource] was added without registering it),
  /// surfaced loudly rather than returning a fabricated default.
  static HipsSurveyEntry entryFor(SurveySource source) {
    final entry = entries[source];
    if (entry == null) {
      throw StateError(
        'No HiPS registry entry for SurveySource.$source — every survey must '
        'be registered in HipsSurveyRegistry.entries.',
      );
    }
    return entry;
  }

  /// The canonical CDS HiPS id for [source] (e.g. `CDS/P/DSS2/red`).
  static String hipsIdFor(SurveySource source) => entryFor(source).hipsId;

  /// The publisher acknowledgement to display whenever [source]'s imagery is on
  /// screen. Always non-empty — every survey in the registry carries one.
  static String attributionCreditFor(SurveySource source) =>
      entryFor(source).attributionCredit;

  /// The canonical attribution page for [source], or null when none is
  /// published.
  static String? attributionUrlFor(SurveySource source) =>
      entryFor(source).attributionUrl;

  /// The verified direct base URL for [source], or `null` if it must be
  /// resolved at runtime.
  static String? verifiedBaseUrlFor(SurveySource source) {
    final entry = entryFor(source);
    return entry.hasVerifiedBaseUrl ? entry.baseUrl : null;
  }

  /// Builds the candidate base URL for runtime resolution of an unverified
  /// survey from its canonical [HipsSurveyEntry.hipsId].
  ///
  /// CDS serves a HiPS id of the form `CDS/P/<survey>` from `<cdsHost>/<survey>`
  /// (the `CDS/P/` registry prefix is stripped). This is the *candidate* the
  /// runtime resolver should confirm by fetching `properties`; it is returned
  /// only for surveys lacking a verified base URL so verified entries always
  /// take precedence over a derived guess.
  static String candidateBaseUrlFor(SurveySource source) {
    final entry = entryFor(source);
    if (entry.baseUrl != null) return entry.baseUrl!;
    const registryPrefix = 'CDS/P/';
    final path = entry.hipsId.startsWith(registryPrefix)
        ? entry.hipsId.substring(registryPrefix.length)
        : entry.hipsId;
    return '$cdsHost/$path';
  }

  /// Asserts (in debug builds) that every [SurveySource] has a registry entry.
  ///
  /// Returns the number of registered entries so a release-mode caller/test can
  /// also verify exhaustiveness without relying on `assert`.
  static int debugAssertExhaustive() {
    for (final source in SurveySource.values) {
      assert(
        entries.containsKey(source),
        'HipsSurveyRegistry is missing an entry for SurveySource.$source',
      );
    }
    return entries.length;
  }
}
