// Regression test for the SubCullRail lasso hit-test column count.
//
// The lasso selects subs by computing the grid geometry analytically and must
// match the real GridView's SliverGridDelegateWithMaxCrossAxisExtent layout
// exactly — otherwise a rubber-band drag rejects the wrong frames. Adding
// `+ spacing` to the numerator produces one extra column at widths near an exact
// multiple of (maxExtent + spacing), so this asserts the rail's column count
// equals Flutter's delegate at those boundary widths.

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/widgets/sub_cull_rail.dart';

void main() {
  // The exact delegate the grid lays out with (extent + spacing from the rail).
  const delegate = SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: SubCullRail.lassoCellExtent,
    mainAxisSpacing: SubCullRail.lassoCellSpacing,
    crossAxisSpacing: SubCullRail.lassoCellSpacing,
    childAspectRatio: 0.82,
  );

  int flutterColumns(double innerWidth) {
    final layout = delegate.getLayout(
      SliverConstraints(
        axisDirection: AxisDirection.down,
        growthDirection: GrowthDirection.forward,
        userScrollDirection: ScrollDirection.idle,
        scrollOffset: 0,
        precedingScrollExtent: 0,
        overlap: 0,
        remainingPaintExtent: 1000,
        crossAxisExtent: innerWidth,
        crossAxisDirection: AxisDirection.right,
        viewportMainAxisExtent: 1000,
        remainingCacheExtent: 1000,
        cacheOrigin: 0,
      ),
    );
    // SliverGridLayout doesn't expose the column count directly; derive it by
    // counting how many leading children share the first row (scrollOffset 0).
    var cols = 0;
    for (var i = 0; i < 64; i++) {
      if (layout.getGeometryForChildIndex(i).scrollOffset != 0) break;
      cols++;
    }
    return cols;
  }

  test('lasso column count matches the GridView delegate at the boundary width',
      () {
    const extent = SubCullRail.lassoCellExtent; // 200
    const spacing = SubCullRail.lassoCellSpacing; // 16
    // The width called out in the finding: an exact multiple of (extent+spacing)
    // minus a hair — where the buggy `+ spacing` numerator over-counted columns.
    const boundary = 2 * (extent + spacing); // 432

    expect(
      SubCullRail.lassoGridColumns(boundary),
      flutterColumns(boundary),
      reason: 'column count must match Flutter at the exact boundary width',
    );
    // Flutter lays out 2 columns at 432 (ceil(432/216)); a `+ spacing` in the
    // numerator gives 3.
    expect(SubCullRail.lassoGridColumns(boundary), 2);
  });

  test('lasso column count matches the delegate across a width sweep', () {
    for (var w = 50.0; w <= 1400.0; w += 7.0) {
      expect(
        SubCullRail.lassoGridColumns(w),
        flutterColumns(w),
        reason: 'mismatch at innerWidth=$w',
      );
    }
  });

  test('lasso column count never drops below one', () {
    expect(SubCullRail.lassoGridColumns(1), 1);
    expect(SubCullRail.lassoGridColumns(0.0001), 1);
  });
}
