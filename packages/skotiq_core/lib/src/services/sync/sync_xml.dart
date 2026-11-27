// The small XML replies of the sync targets (a WebDAV PROPFIND multistatus,
// an S3 list-objects-v2 result) are read with these scanners instead of a
// full XML dependency. Servers disagree on the namespace prefix (`d:`, `D:`,
// `lp1:`, none at all), so the patterns match the local element name under
// any prefix.

/// Every `<localName ...>...</localName>` block, prefix included.
RegExp xmlBlock(String localName, {bool caseSensitive = true}) => RegExp(
  '<(?:[A-Za-z0-9_-]+:)?$localName[\\s>].*?'
  '</(?:[A-Za-z0-9_-]+:)?$localName>',
  dotAll: true,
  caseSensitive: caseSensitive,
);

/// The text of a `<localName>` element as group 1.
RegExp xmlElementText(String localName, {bool caseSensitive = true}) => RegExp(
  '<(?:[A-Za-z0-9_-]+:)?$localName[^>]*>(.*?)'
  '</(?:[A-Za-z0-9_-]+:)?$localName>',
  dotAll: true,
  caseSensitive: caseSensitive,
);

/// [value] with the five predefined XML entities decoded.
String xmlUnescape(String value) => value
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');
