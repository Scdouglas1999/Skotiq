/// Sentence case for the node palette's CHROME.
///
/// 02 rule 3 and 06's copy rules want "Take exposures", not "Take Exposures",
/// and the mockup draws it that way. The strings themselves come from
/// `nodePaletteProvider` in `skotiq_core`, which this wave may not touch
/// (07: "Do not touch packages/skotiq_core"), so the palette lowers them
/// where it DRAWS them.
///
/// This is deliberately chrome-only. The name a node carries once it is in a
/// sequence is the user's data — `NodePaletteItem.createNode()` sets it, the
/// operator renames it, and it is written into their saved `.nsq`. Lowering
/// that would rewrite what the app saved for them, so the tree, the canvas bar
/// and the properties column all keep the string exactly as it is stored.
library;

/// Words that keep their capital: acronyms, proper nouns and protocol names.
const Set<String> _keepCapitalised = <String>{
  'AF',
  'HFR',
  'FWHM',
  'RMS',
  'ASCOM',
  'INDI',
  'PHD2',
  'AI',
  'NINA',
  'SGP',
  'FITS',
  'XISF',
  'RA',
  'Dec',
  'DSO',
  'NGC',
  'IC',
  'UTC',
  'LST',
  'AAVSO',
  'TNS',
  'MPC',
  'OSC',
  'LRGB',
  'SHO',
  'DSLR',
  'CMOS',
  'CCD',
  'USB',
  'GPS',
  'Alpaca',
  'Skotiq',
  'Telegram',
  'Discord',
  'Slack',
  'Pushover',
};

final RegExp _plainWord = RegExp(r'^[A-Z][a-z]+$');

/// [label] with every word after the first lowered, unless it is an acronym or
/// a proper noun.
///
/// "Take Exposures" -> "Take exposures"; "Photometry Run (template)" ->
/// "Photometry run (template)"; "HFR Triggered AF" -> "HFR triggered AF".
String paletteSentenceCase(String label) {
  if (label.isEmpty) return label;
  final words = label.split(' ');
  final out = <String>[words.first];
  for (final word in words.skip(1)) {
    final core = word.replaceAll(RegExp(r'^[(\[]+|[)\],.:;]+$'), '');
    if (_keepCapitalised.contains(core) || !_plainWord.hasMatch(core)) {
      out.add(word);
      continue;
    }
    final at = word.indexOf(core);
    out.add(word.substring(0, at) +
        core[0].toLowerCase() +
        core.substring(1) +
        word.substring(at + core.length));
  }
  return out.join(' ');
}
