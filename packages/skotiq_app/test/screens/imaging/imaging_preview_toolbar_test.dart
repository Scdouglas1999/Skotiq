// Widget tests for the off-canvas ImagingPreviewToolbar.
//
// The toolbar is a slim strip ABOVE the live preview, not an on-image overlay
// bar, and its overlay toggles live in a single labelled "Overlays" popover.
//
// These tests pin that the Overlays menu flips the real providers. They
// exercise the catalog-overlay row because it toggles a plain StateProvider
// (catalogOverlayEnabledProvider) readable straight from the container — no
// callback indirection — so a green assertion proves the menu→provider wiring
// end to end, not just that a row rendered.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/imaging_screen.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_preview_toolbar.dart';
import 'package:skotiq_app/widgets/catalog_overlay_widget.dart'
    show CatalogOverlayPopover;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// Drive several frames so async-provider overrides flow into the tree and the
/// screen's fade controller completes, without pumpAndSettle (BigActionButton's
/// loading animation never settles).
Future<void> _drainAsyncFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void _swallowKnownOverflows() {
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exceptionAsString().contains('overflowed')) return;
    defaultOnError?.call(details);
  };
  addTearDown(() => FlutterError.onError = defaultOnError);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'toolbar_renders_above_preview: ImagingPreviewToolbar is present at '
      'desktop width', (tester) async {
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drainAsyncFrames(tester);
    addTearDown(() async => handle.database.close());

    expect(find.byType(ImagingPreviewToolbar), findsOneWidget,
        reason:
            'The relocated, off-canvas preview toolbar must render once above '
            'the live preview.');
    // The single labelled Overlays control replaces the six former icons.
    expect(find.text('Overlays'), findsOneWidget,
        reason:
            'The six loose overlay icons collapsed into one labelled Overlays '
            'popover trigger.');
  });

  testWidgets(
      'overlays_menu_toggles_catalog_overlay_provider: tapping the Catalog '
      'overlay row flips catalogOverlayEnabledProvider', (tester) async {
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drainAsyncFrames(tester);
    addTearDown(() async => handle.database.close());

    // Baseline: the catalog overlay starts disabled.
    expect(handle.container.read(catalogOverlayEnabledProvider), isFalse,
        reason: 'Catalog overlay defaults off.');

    // Open the Overlays popover. Fixed-step pumps instead of pumpAndSettle —
    // the imaging control panel's BigActionButton runs a repeating loading
    // animation that never settles, so pumpAndSettle would time out.
    await tester.tap(find.text('Overlays'));
    await _drainAsyncFrames(tester);

    // The popover lists labelled overlay rows; tap the Catalog overlay one.
    expect(find.text('Catalog overlay'), findsOneWidget,
        reason:
            'The Overlays popover must expose a labelled Catalog overlay row '
            'wired to the same provider the old catalog icon drove.');
    await tester.tap(find.text('Catalog overlay'));
    // PopupMenuItem.onTap fires after the menu dismisses on a post-frame
    // callback; drain frames so that write lands.
    await _drainAsyncFrames(tester);

    expect(handle.container.read(catalogOverlayEnabledProvider), isTrue,
        reason: 'Selecting the Catalog overlay row must flip '
            'catalogOverlayEnabledProvider true — proving the new menu drives '
            'the same provider as the retired loose icon.');
  });

  testWidgets(
      'overlays_menu_label_is_not_squeezed_by_its_description: the Readouts '
      'row renders its label on one unbroken line', (tester) async {
    // The Readouts row is the only one carrying a trailing description
    // ("Histogram, HFR / stars, image stats"). Laid out beside the label it
    // claimed its full intrinsic width first and left the label a ~29 px
    // sliver inside the popup's 296 px cap, so "Readouts" rendered broken
    // across two lines as "Rea" / "dou".
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drainAsyncFrames(tester);
    addTearDown(() async => handle.database.close());

    await tester.tap(find.text('Overlays'));
    await _drainAsyncFrames(tester);

    expect(find.text('Readouts'), findsOneWidget,
        reason: 'The Overlays popover must expose the Readouts row.');
    expect(find.text('Histogram, HFR / stars, image stats'), findsOneWidget,
        reason: 'The description must still be shown, just not competing with '
            'the label for the same line.');

    // "Crosshair" is a sibling row with the identical label style and no
    // description, so it is the height of exactly one line. A wrapped
    // "Readouts" is twice that.
    final oneLineHeight = tester.getSize(find.text('Crosshair')).height;
    expect(tester.getSize(find.text('Readouts')).height,
        closeTo(oneLineHeight, 0.5),
        reason: 'The control name must occupy exactly one line — two lines is '
            'the "Rea" / "dou" break.');

    final paragraph =
        tester.renderObject<RenderParagraph>(find.text('Readouts'));
    expect(paragraph.didExceedMaxLines, isFalse,
        reason: 'The control name must not be ellipsised either: a label '
            'squeezed to "Rea…" is just as unreadable as one broken in half.');
  });

  // W17 regression: `PopupMenuButton.constraints` bounds the OPENED MENU, not
  // the trigger — a `tightFor(iconButtonSizeSm)` there pinned the catalog
  // popover to a 28 x 28 box and clipped every control inside it.

  testWidgets(
      'catalog_settings_popover_opens_at_natural_size: the menu is not '
      'pinned to the 28 px icon box', (tester) async {
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drainAsyncFrames(tester);
    addTearDown(() async => handle.database.close());

    await _openCatalogSettings(tester);

    final popover = find.byType(CatalogOverlayPopover);
    expect(popover, findsOneWidget,
        reason: 'Tapping the catalog settings glyph must open the popover.');

    // clampPanelWidth(1600 * 0.3, min: 200, max: 240) = 240. The defect
    // rendered it at exactly SkotiqTokens.iconButtonSizeSm (28).
    expect(tester.getSize(popover).width, closeTo(240.0, 0.5),
        reason: 'The popover must render at its intended 200–240 px width — '
            'a 28 px answer means the menu inherited the icon button box.');

    // The trigger keeps its 28 px footprint — the button's own size, set on
    // the IconButton, not the menu's constraints.
    expect(
        tester.getSize(_catalogSettingsButton(tester)),
        equals(const Size(SkotiqTokens.iconButtonSizeSm,
            SkotiqTokens.iconButtonSizeSm)),
        reason: 'The settings trigger must stay a 28 px icon button — '
            'sizing the menu never sized the button.');

    // Anchored under the button: the popover's top edge sits below the
    // trigger's bottom edge.
    final buttonRect = tester.getRect(_catalogSettingsButton(tester));
    final popoverRect = tester.getRect(popover);
    expect(popoverRect.top, greaterThanOrEqualTo(buttonRect.bottom),
        reason: 'PopupMenuPosition.under must keep the popover below its '
            'trigger.');

    // Controls present inside the opened popover. Finders are scoped to the
    // popover — the capture panel carries its own dropdowns and switches.
    expect(find.text('Magnitude limit'), findsOneWidget);
    expect(
        find.descendant(of: popover, matching: find.byType(SkotiqDropdown)),
        findsOneWidget);
    expect(find.text('DSOs (Messier / NGC / IC)'), findsOneWidget);
    expect(find.text('Bright stars (HYG)'), findsOneWidget);
    expect(
        find.descendant(of: popover, matching: find.byType(SkotiqSwitch)),
        findsNWidgets(2));
  });

  testWidgets(
      'catalog_settings_popover_controls_are_live: toggles and the '
      'magnitude dropdown write their providers', (tester) async {
    _swallowKnownOverflows();
    final handle = await pumpAppScreen(
      tester,
      const ImagingScreen(),
      size: const Size(1600, 900),
      settle: false,
    );
    await _drainAsyncFrames(tester);
    addTearDown(() async => handle.database.close());

    // Defaults: DSOs on, bright stars off, magnitude limit 10.
    expect(handle.container.read(catalogOverlayIncludeDsosProvider), isTrue);
    expect(handle.container.read(catalogOverlayIncludeStarsProvider), isFalse);
    expect(handle.container.read(catalogOverlayMagnitudeLimitProvider), 10.0);

    await _openCatalogSettings(tester);

    final switches = find.descendant(
      of: find.byType(CatalogOverlayPopover),
      matching: find.byType(SkotiqSwitch),
    );
    await tester.tap(switches.at(0)); // DSOs
    await _drainAsyncFrames(tester);
    expect(handle.container.read(catalogOverlayIncludeDsosProvider), isFalse,
        reason: 'The DSO toggle must flip catalogOverlayIncludeDsosProvider.');

    await tester.tap(switches.at(1)); // Bright stars
    await _drainAsyncFrames(tester);
    expect(handle.container.read(catalogOverlayIncludeStarsProvider), isTrue,
        reason:
            'The star toggle must flip catalogOverlayIncludeStarsProvider.');

    // The popover survives its own controls: toggles must not pop the route.
    expect(find.byType(CatalogOverlayPopover), findsOneWidget,
        reason: 'Adjusting a control inside the popover must not dismiss it.');

    // The magnitude dropdown opens its own route on top of the popover.
    await tester.tap(find.descendant(
        of: find.byType(CatalogOverlayPopover),
        matching: find.byType(SkotiqDropdown)));
    await _drainAsyncFrames(tester);
    await tester.tap(find.text('Mag <= 14'));
    await _drainAsyncFrames(tester);
    expect(handle.container.read(catalogOverlayMagnitudeLimitProvider), 14.0,
        reason: 'Picking a magnitude bucket must update '
            'catalogOverlayMagnitudeLimitProvider.');
    expect(find.byType(CatalogOverlayPopover), findsOneWidget,
        reason: 'Choosing a magnitude must leave the settings popover open.');
  });

  testWidgets(
      'catalog_settings_popover_stays_on_screen: button near the right edge '
      'of a narrow window must not push the menu off-screen', (tester) async {
    _swallowKnownOverflows();
    // A bare toolbar at 420 px scrolls its contents, leaving the settings
    // glyph off the trailing edge; ensureVisible scrolls it to the right edge
    // of the viewport — the worst case for a menu that opens under it.
    final handle = await pumpAppScreen(
      tester,
      const ImagingPreviewToolbar(
        showCrosshair: false,
        showStarOverlay: false,
        isStoppingCapture: false,
        onZoomIn: _noop,
        onZoomOut: _noop,
        onFitToWindow: _noop,
        onZoom1to1: _noop,
        onAbortCapture: _noop,
        onToggleCrosshair: _noop,
        onToggleStarOverlay: _noop,
      ),
      size: const Size(420, 200),
      settle: false,
    );
    await _drainAsyncFrames(tester);
    addTearDown(() async => handle.database.close());

    final button = _catalogSettingsButton(tester);
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await _drainAsyncFrames(tester);
    await tester.tap(button);
    await _drainAsyncFrames(tester);

    final popover = find.byType(CatalogOverlayPopover);
    expect(popover, findsOneWidget);
    final rect = tester.getRect(popover);
    // clampPanelWidth(420 * 0.3 = 126, min: 200, max: 240) = 200.
    expect(rect.width, closeTo(200.0, 0.5),
        reason: 'The popover keeps its 200 px floor on a narrow window.');
    expect(rect.left, greaterThanOrEqualTo(0.0));
    expect(rect.right, lessThanOrEqualTo(420.0),
        reason: 'The menu must clamp inside the screen edge — a popover '
            'hanging past the window edge is clipped off-screen.');
  });
}

void _noop() {}

Finder _catalogSettingsButton(WidgetTester tester) => find.descendant(
      of: find.byType(ImagingPreviewToolbar),
      matching: find.byType(PopupMenuButton<String>),
    );

/// Taps the catalog-overlay settings glyph and lets the popup route land.
Future<void> _openCatalogSettings(WidgetTester tester) async {
  final button = _catalogSettingsButton(tester);
  expect(button, findsOneWidget,
      reason: 'The toolbar must expose exactly one PopupMenuButton<String> — '
          'the catalog-overlay settings trigger.');
  await tester.tap(button);
  await _drainAsyncFrames(tester);
}
