import 'package:flutter/widgets.dart';

/// [path] shortened from the front, `…/captures/Flats`, keeping as many
/// trailing folders as fit [maxWidth] in [style]: the end of a path is what
/// tells two folders apart. The whole path when it fits; the last folder
/// alone when nothing shorter does (the caller's ellipsis cuts that).
String pathTail(
  String path, {
  required double maxWidth,
  required TextStyle style,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  bool fits(String text) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width <= maxWidth;
  }

  if (fits(path)) return path;
  final separator = path.contains('\\') && !path.contains('/') ? '\\' : '/';
  final parts = path
      .split(RegExp(r'[\\/]'))
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  for (var keep = parts.length - 1; keep > 1; keep--) {
    final tail = '…$separator${parts.sublist(parts.length - keep).join(separator)}';
    if (fits(tail)) return tail;
  }
  return parts.isEmpty ? path : '…$separator${parts.last}';
}
