/// How an integrated master is named and where its preview sits, written and
/// read in one place.
library;

import 'package:path/path.dart' as p;

/// Between the target and the filter in a master's name.
const String kMasterNameSeparator = ' · ';

/// The name Session Review gives a master: `<target> · <filter>`, `Master`
/// when no target is known.
String integratedMasterName({String? targetName, String? filter}) {
  final base = (targetName != null && targetName.trim().isNotEmpty)
      ? targetName.trim()
      : 'Master';
  if (filter != null && filter.trim().isNotEmpty) {
    return '$base$kMasterNameSeparator${filter.trim()}';
  }
  return base;
}

/// The target a master's [name] says, with its [filter] and anything after
/// [kMasterNameSeparator] taken off. Empty when the name says nothing else.
String targetInMasterName(String name, String? filter) {
  var target = name.trim();
  final trimmedFilter = filter?.trim();
  if (trimmedFilter != null && trimmedFilter.isNotEmpty) {
    for (final separator in const [kMasterNameSeparator, ' - ', ' ']) {
      final suffix = '$separator$trimmedFilter';
      if (target.toLowerCase().endsWith(suffix.toLowerCase())) {
        target = target.substring(0, target.length - suffix.length).trim();
        break;
      }
    }
  }
  final dot = target.indexOf(kMasterNameSeparator);
  if (dot > 0) target = target.substring(0, dot).trim();
  return target;
}

/// The stretched preview PNG beside a master or product FITS at [fitsPath].
String masterPreviewPath(String fitsPath) => p.setExtension(fitsPath, '.png');
