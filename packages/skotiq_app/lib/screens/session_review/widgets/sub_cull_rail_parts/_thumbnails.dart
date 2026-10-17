// Thumbnail cache providers, thumbnail widgets, accept toggle and blink view.
part of '../sub_cull_rail.dart';

/// How many decoded sub thumbnails stay resident.
///
/// Sized well past a full viewport of the 200px grid so ordinary scrolling
/// never evicts, and small enough that a 500-sub night cannot pin the whole
/// set: at a typical ~40 KB JPEG that is roughly 5 MB.
const int _subThumbnailCacheCapacity = 128;

/// Decoded thumbnail bytes for one sub, memoized across cell recycling.
///
/// `GridView.builder` disposes a cell the moment it leaves the viewport, so
/// fetching in the tile's own `initState` re-issued a decode (FFI backend) or a
/// full HTTP GET (paired tablet) every time the operator scrolled back. Keyed
/// on the image id and retained through [_subThumbnailRetentionProvider], which
/// bounds how many stay in memory.
final subThumbnailProvider =
    FutureProvider.autoDispose.family<Uint8List, int>((ref, imageId) {
  ref.watch(_subThumbnailRetentionProvider).retain(imageId, ref.keepAlive());
  return ref.watch(imagingBackendProvider).getImageThumbnail(imageId);
});

final _subThumbnailRetentionProvider = Provider<_ThumbnailRetention>((ref) {
  final retention = _ThumbnailRetention(_subThumbnailCacheCapacity);
  ref.onDispose(retention.clear);
  return retention;
});

/// Holds the keep-alive links for the most recently requested thumbnails and
/// closes the oldest once [capacity] is exceeded, letting Riverpod dispose that
/// entry and free its bytes.
class _ThumbnailRetention {
  _ThumbnailRetention(this.capacity);

  final int capacity;
  final Map<int, KeepAliveLink> _links = <int, KeepAliveLink>{};

  void retain(int imageId, KeepAliveLink link) {
    _links.remove(imageId)?.close();
    _links[imageId] = link;
    while (_links.length > capacity) {
      _links.remove(_links.keys.first)?.close();
    }
  }

  void clear() {
    for (final link in _links.values) {
      link.close();
    }
    _links.clear();
  }
}

class _SubThumbnail extends ConsumerStatefulWidget {
  final int imageId;
  final SkotiqColors colors;

  const _SubThumbnail({required this.imageId, required this.colors});

  @override
  ConsumerState<_SubThumbnail> createState() => _SubThumbnailState();
}

class _SubThumbnailState extends ConsumerState<_SubThumbnail> {
  @override
  Widget build(BuildContext context) {
    final thumbnail = ref.watch(subThumbnailProvider(widget.imageId));
    return Container(
      color: widget.colors.surface,
      child: thumbnail.when(
        loading: () => const Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: SkotiqMark(size: 18),
          ),
        ),
        error: (_, __) => _placeholder(),
        // Decoded at cell width, not at the 512 px the backend encoded. A
        // 500-sub night is 500 of these tiles.
        data: (bytes) => bytes.isEmpty
            ? _placeholder()
            : LayoutBuilder(
                builder: (context, constraints) => Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  cacheWidth: thumbnailDecodeWidth(
                    context,
                    constraints.maxWidth,
                  ),
                  errorBuilder: (_, __, ___) => _placeholder(),
                ),
              ),
      ),
    );
  }

  Widget _placeholder() => Center(
        child: Icon(
          SkotiqIcons.image,
          size: 28,
          color: widget.colors.textMuted,
        ),
      );
}

class _AcceptToggle extends StatelessWidget {
  final bool accepted;
  final VoidCallback onTap;
  final SkotiqColors colors;

  const _AcceptToggle({
    required this.accepted,
    required this.onTap,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final color = accepted ? colors.success : colors.warning;
    return Tooltip(
      message: accepted ? 'Reject this sub' : 'Accept this sub',
      child: Semantics(
          button: true,
          enabled: true,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.9),
                shape: BoxShape.circle,
              ),
              child: Icon(
                accepted ? SkotiqIcons.check : SkotiqIcons.error,
                size: 14,
                color: colors.onPrimary,
              ),
            ),
          )),
    );
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;

  const _Badge({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
      ),
      child: Text(
        text,
        style: SkotiqTypography.captionSm.copyWith(
          color: colors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Full-bleed single-sub view used by blink mode.
class _BlinkView extends ConsumerWidget {
  final DbCapturedImage sub;
  const _BlinkView({required this.sub});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    return Container(
      color: colors.background,
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        children: [
          Expanded(
            child: FutureBuilder<Uint8List>(
              future:
                  ref.read(imagingBackendProvider).getImageThumbnail(sub.id),
              builder: (context, snapshot) {
                final bytes = snapshot.data;
                if (bytes != null && bytes.isNotEmpty) {
                  return Image.memory(bytes, fit: BoxFit.contain);
                }
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: SkotiqMark(size: 36),
                  );
                }
                return Center(
                  child: Icon(SkotiqIcons.imageOff,
                      size: 48, color: colors.textMuted),
                );
              },
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            '${sub.fileName} · ${filterLabel(sub.filter)} · '
            '${sub.exposureDuration.toInt()}s'
            '${sub.hfr != null ? ' · HFR ${sub.hfr!.toStringAsFixed(2)}' : ''}',
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
          ),
        ],
      ),
    );
  }
}
