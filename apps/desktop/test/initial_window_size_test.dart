import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/main.dart' show initialWindowSize;

void main() {
  testWidgets('a 1080p laptop at 125% gets a window that fits its screen', (
    tester,
  ) async {
    tester.view.display.devicePixelRatio = 1.25;
    tester.view.display.size = const Size(1920, 1080);
    addTearDown(tester.view.display.reset);

    final size = initialWindowSize([tester.view.display]);
    expect(size.width, lessThanOrEqualTo(1536));
    expect(size.height, lessThanOrEqualTo(864 * 0.88));
  });

  testWidgets('a large screen gets the preferred 1600 x 900', (tester) async {
    tester.view.display.devicePixelRatio = 1.0;
    tester.view.display.size = const Size(2560, 1440);
    addTearDown(tester.view.display.reset);

    expect(initialWindowSize([tester.view.display]), const Size(1600, 900));
  });

  test('no display reported keeps the preferred size', () {
    expect(initialWindowSize(const []), const Size(1600, 900));
  });
}
