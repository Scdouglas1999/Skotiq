/// One card to set in a frame file's metadata, FITS or XISF: a string, a
/// whole number or a real number, with an optional comment.
class FitsKeywordWrite {
  final String keyword;
  final String? comment;
  final String? stringValue;
  final int? intValue;
  final double? doubleValue;

  const FitsKeywordWrite._({
    required this.keyword,
    required this.comment,
    required this.stringValue,
    required this.intValue,
    required this.doubleValue,
  });

  factory FitsKeywordWrite.string(
    String keyword,
    String value, {
    String? comment,
  }) => FitsKeywordWrite._(
    keyword: keyword,
    comment: comment,
    stringValue: value,
    intValue: null,
    doubleValue: null,
  );

  factory FitsKeywordWrite.integer(
    String keyword,
    int value, {
    String? comment,
  }) => FitsKeywordWrite._(
    keyword: keyword,
    comment: comment,
    stringValue: null,
    intValue: value,
    doubleValue: null,
  );

  factory FitsKeywordWrite.floating(
    String keyword,
    double value, {
    String? comment,
  }) => FitsKeywordWrite._(
    keyword: keyword,
    comment: comment,
    stringValue: null,
    intValue: null,
    doubleValue: value,
  );
}
