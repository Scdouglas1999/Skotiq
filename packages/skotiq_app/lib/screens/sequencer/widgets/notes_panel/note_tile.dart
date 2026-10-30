part of '../notes_panel.dart';

class _NoteTile extends StatelessWidget {
  final JournalNote note;
  final SkotiqColors colors;
  final int maxBodyLines;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _NoteTile({
    required this.note,
    required this.colors,
    required this.maxBodyLines,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('MMM d, yyyy · HH:mm');
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (note.sentiment != null) ...[
                Text(note.sentiment!,
                    style:
                        const TextStyle(fontSize: SkotiqTypography.fontSize14)),
                const SizedBox(width: 6),
              ],
              if (note.title != null && note.title!.isNotEmpty)
                Expanded(
                  child: Text(
                    note.title!,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize13,
                      fontWeight: FontWeight.w700,
                      color: colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              else
                Expanded(
                  child: Text(
                    dateFormat.format(note.createdAt),
                    style: SkotiqTypography.h6
                        .copyWith(color: colors.textSecondary),
                  ),
                ),
              if (note.sequenceRunId != null)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: SkotiqDecorations.statusChip(
                    colors.accent,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                    bordered: false,
                  ),
                  child: Text(
                    'run #${note.sequenceRunId}',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize10,
                      fontWeight: FontWeight.w600,
                      color: colors.accent,
                    ),
                  ),
                ),
              IconButton(
                onPressed: onEdit,
                icon: const Icon(LucideIcons.edit3, size: 14),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                tooltip: 'Edit',
              ),
              IconButton(
                onPressed: onDelete,
                icon: const Icon(LucideIcons.trash2, size: 14),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                tooltip: 'Delete',
                color: colors.error,
              ),
            ],
          ),
          if (note.title != null && note.title!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                dateFormat.format(note.createdAt),
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: colors.textMuted),
              ),
            ),
          if (note.body.isNotEmpty) ...[
            const SizedBox(height: 6),
            // Render note bodies as markdown so **bold**,
            // links, code-fences, and bullet lists land the way the user
            // typed them. `MarkdownBody` does not support a hard
            // `maxLines` clamp; we approximate it by truncating the
            // input string to ~80 characters per line of the requested
            // maxBodyLines and tagging an ellipsis when we cut.
            // `selectable: false` keeps the tile's onTap pass through
            // to the underlying NoteTile gesture; the full editor
            // dialog rehydrates the entire body.
            MarkdownBody(
              data: _truncateForPreview(note.body, maxBodyLines),
              shrinkWrap: true,
              fitContent: true,
              styleSheet: _noteBodyMarkdownStyle(context, colors),
              onTapLink: (_, href, __) {
                // Notes are local journal entries; opening external
                // links from a non-trusted source unilaterally would be
                // a UX surprise. Copy the href to the clipboard instead so
                // the affordance is honest — the user can paste it into a
                // browser if they choose.
                if (href != null && href.isNotEmpty) {
                  Clipboard.setData(ClipboardData(text: href));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Link copied: $href'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              },
            ),
          ],
          if (note.tags.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final tag in note.tags)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: SkotiqDecorations.tintedBadge(
                      colors.primary,
                      borderRadius:
                          BorderRadius.circular(SkotiqTokens.radiusInline4),
                    ),
                    child: Text(
                      '#$tag',
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize10,
                        fontWeight: FontWeight.w500,
                        color: colors.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (note.attachments.isNotEmpty) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: [
                for (final path in note.attachments)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.paperclip,
                          size: 11, color: colors.textMuted),
                      const SizedBox(width: 3),
                      Text(
                        path.split(RegExp(r'[\\/]')).last,
                        style: TextStyle(
                            fontSize: SkotiqTypography.fontSize10,
                            color: colors.textMuted),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// Markdown rendering helpers for _NoteTile

/// Truncate the note body to ~`maxLines * 80` characters before passing
/// it to [MarkdownBody], appending an ellipsis when we cut. We do this
/// rather than relying on `MarkdownBody`'s built-in clamping (it has
/// none) because the tile is a fixed-height preview that needs to fit
/// alongside the title row + tag chips + edit/delete affordances.
///
/// The constant 80 chars/line is a deliberate over-estimate so wide
/// markdown blocks (e.g. tables, code) still get a reasonable preview
/// without growing past the tile bounds.
String _truncateForPreview(String body, int maxLines) {
  final softLimit = maxLines * 80;
  if (body.length <= softLimit) return body;
  // Cut at the last newline before the soft limit so we don't bisect a
  // markdown structure (bullet, table row, fenced block).
  var cut = body.lastIndexOf('\n', softLimit);
  if (cut < softLimit ~/ 2) cut = softLimit; // give up on line-aware cut
  final truncated = '${body.substring(0, cut).trimRight()}…';
  return _balanceMarkdownFences(truncated);
}

/// Repair markdown structures the [_truncateForPreview] cut may have left
/// open. An unbalanced ``` fence makes [MarkdownBody] swallow everything
/// after it as code (and can break rendering of the surrounding tile), so
/// when the truncated string has an odd number of fences we append a
/// closing fence on its own line.
String _balanceMarkdownFences(String text) {
  final fenceCount = '```'.allMatches(text).length;
  if (fenceCount.isOdd) {
    return '$text\n```';
  }
  return text;
}

/// Build a [MarkdownStyleSheet] that pulls from the design-system
/// tokens so note bodies match the rest of the app. We keep the same
/// 12 pt body font as the original `Text` widget for visual parity
/// with previous releases.
MarkdownStyleSheet _noteBodyMarkdownStyle(
  BuildContext context,
  SkotiqColors colors,
) {
  final base = TextStyle(
      fontSize: SkotiqTypography.fontSize12, color: colors.textPrimary);
  return MarkdownStyleSheet(
    p: base,
    h1: base.copyWith(
      fontSize: SkotiqTypography.fontSize14,
      fontWeight: FontWeight.w700,
    ),
    h2: base.copyWith(
      fontSize: SkotiqTypography.fontSize13,
      fontWeight: FontWeight.w700,
    ),
    h3: base.copyWith(
      fontSize: SkotiqTypography.fontSize12,
      fontWeight: FontWeight.w600,
    ),
    em: base.copyWith(fontStyle: FontStyle.italic),
    strong: base.copyWith(fontWeight: FontWeight.w700),
    code: base.copyWith(
      fontFamily: SkotiqTypography.fontFamilyMono,
      fontSize: SkotiqTypography.fontSize11,
      backgroundColor: colors.surfaceAlt,
      color: colors.accent,
    ),
    codeblockDecoration: BoxDecoration(
      color: colors.surfaceAlt,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
      border: Border.all(color: colors.border),
    ),
    codeblockPadding: const EdgeInsets.all(6),
    a: base.copyWith(
      color: colors.primary,
      decoration: TextDecoration.underline,
    ),
    blockquoteDecoration: BoxDecoration(
      color: colors.surfaceAlt,
      border: Border(
        left: BorderSide(color: colors.primary, width: 3),
      ),
    ),
    blockquotePadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    listBullet: base,
    tableHead: base.copyWith(fontWeight: FontWeight.w600),
    tableBody: base,
    tableBorder: TableBorder.all(color: colors.border, width: 0.5),
  );
}

// Note editor dialog (create + edit)

/// Modal for creating or editing a [JournalNote]. Returns the saved
/// note via `Navigator.pop`, or `null` when the user cancels.
