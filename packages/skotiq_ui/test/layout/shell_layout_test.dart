import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

ShellLayout _touch(double w, double h) =>
    ShellLayout(size: Size(w, h), touchDevice: true, drawsWindowFrame: false);

ShellLayout _desktop(double w, double h) =>
    ShellLayout(size: Size(w, h), touchDevice: false, drawsWindowFrame: true);

void main() {
  group('touch device', () {
    test('a phone is a phone in both orientations', () {
      for (final layout in [_touch(390, 844), _touch(844, 390)]) {
        expect(layout.isPhone, isTrue);
        expect(layout.deviceClass, DeviceClass.phone);
        expect(layout.usesBottomNavigation, isTrue);
        expect(layout.hasInstrumentBar, isFalse);
        expect(layout.phoneChrome, isTrue);
      }
      expect(_touch(390, 844).navigation, ShellNavKind.bottomBar);
      expect(_touch(844, 390).navigation, ShellNavKind.phoneRail);
      expect(_touch(905, 369).isPhone, isTrue);
    });

    test('the phone boundary is the short side at 600', () {
      expect(_touch(599, 1000).isPhone, isTrue);
      expect(_touch(600, 1000).isPhone, isFalse);
      expect(_touch(1000, 599).isPhone, isTrue);
    });

    test('a tablet never takes the side bar', () {
      final portrait = _touch(768, 1024);
      final landscape = _touch(1024, 768);
      expect(portrait.deviceClass, DeviceClass.tablet);
      expect(landscape.deviceClass, DeviceClass.tablet);
      expect(portrait.navigation, ShellNavKind.bottomBar);
      expect(landscape.navigation, ShellNavKind.phoneRail);
      expect(landscape.hasInstrumentBar, isFalse);
      expect(_touch(1366, 1024).deviceClass, DeviceClass.desktop);
    });

    test('the header is narrow by window width', () {
      expect(_touch(390, 844).narrowWindow, isTrue);
      expect(_touch(844, 390).narrowWindow, isFalse);
      expect(_touch(767, 1024).narrowWindow, isTrue);
      expect(_touch(768, 1024).narrowWindow, isFalse);
    });
  });

  group('desktop window', () {
    test('a full window takes the side bar and the instrument bar', () {
      final layout = _desktop(1440, 900);
      expect(layout.isPhone, isFalse);
      expect(layout.deviceClass, DeviceClass.desktop);
      expect(layout.navigation, ShellNavKind.sideBar);
      expect(layout.hasInstrumentBar, isTrue);
      expect(layout.narrowWindow, isFalse);
      expect(_desktop(1024, 768).navigation, ShellNavKind.sideBar);
      expect(_desktop(1024, 768).deviceClass, DeviceClass.desktop);
      expect(_desktop(1023, 768).deviceClass, DeviceClass.tablet);
    });

    test('a narrow window takes the bottom bar and keeps its frame', () {
      final layout = _desktop(390, 844);
      expect(layout.isPhone, isTrue);
      expect(layout.navigation, ShellNavKind.bottomBar);
      expect(layout.phoneChrome, isFalse);
      expect(_desktop(767, 900).navigation, ShellNavKind.bottomBar);
      expect(_desktop(768, 900).navigation, ShellNavKind.sideBar);
      expect(_desktop(599, 900).isPhone, isTrue);
      expect(_desktop(600, 900).isPhone, isFalse);
    });

    test('a window shorter than a phone is a phone on its side', () {
      final layout = _desktop(844, 390);
      expect(layout.isPhone, isTrue);
      expect(layout.deviceClass, DeviceClass.phone);
      expect(layout.navigation, ShellNavKind.bottomBar);
      expect(layout.hasInstrumentBar, isFalse);
      expect(_desktop(1200, 599).navigation, ShellNavKind.bottomBar);
      expect(_desktop(1200, 600).navigation, ShellNavKind.sideBar);
    });
  });

  testWidgets('a widget with no scope is laid out as a desktop window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    late ShellLayout unscoped;
    late ShellLayout scoped;
    await tester.pumpWidget(
      Column(
        textDirection: TextDirection.ltr,
        children: [
          Builder(
            builder: (context) {
              unscoped = ShellLayout.of(context);
              return const SizedBox.shrink();
            },
          ),
          ShellLayoutScope(
            touchDevice: true,
            drawsWindowFrame: false,
            child: Builder(
              builder: (context) {
                scoped = ShellLayout.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ],
      ),
    );
    expect(unscoped, _desktop(844, 390));
    expect(scoped, _touch(844, 390));
  });
}
