part of '../analytics_screen.dart';

class _SessionHistorySkeletonList extends StatelessWidget {
  const _SessionHistorySkeletonList();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: 6,
      itemBuilder: (context, _) => const Padding(
        padding: EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
        child: ShimmerLoading(
          child: SkotiqPanel(
            child: SizedBox(
              height: 56,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SkeletonBox(width: 180, height: 14),
                        SizedBox(height: 8),
                        SkeletonBox(width: 120, height: 12),
                      ],
                    ),
                  ),
                  SkeletonBox(width: 220, height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
