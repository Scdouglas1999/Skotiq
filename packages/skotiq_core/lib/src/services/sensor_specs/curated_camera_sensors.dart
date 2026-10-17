import 'camera_sensor_entry.dart';
import 'published_figure.dart';

/// Source documents for [kCuratedCameraSensors]. Every figure in a row comes
/// from the document its `source` names; nothing here is measured, averaged,
/// inferred from a sibling model or taken from a third-party sensor database.
///
/// The ZWO manuals were retrieved 2026-09-14 and each states its own revision
/// and date, which is why the revision is part of the citation: ZWO revises
/// figures between revisions (the ASI294 gained separate mono/colour rows
/// between Rev 1.x and Rev 2.2).
const _zwoAsi1600Manual =
    'ZWO "ASI1600 Manual" Rev 1.5, Aug 2021, sections 2 and 4 — '
    'https://i.zwoastro.com/zwo-website/manuals/ASI1600_Manual_EN_V1.5.pdf';
const _zwoAsi2600Manual =
    'ZWO "ASI2600 Manual" Rev 1.3, Jul 2021, sections 2, 3 and 4 — '
    'https://astronomy-imaging-camera.com/manuals/ASI2600_Manual_EN_V1.3.pdf';
const _zwoAsi6200Manual =
    'ZWO "ASI6200 Manual" EN, sections 2, 3 and 4 — '
    'https://astronomy-imaging-camera.com/manuals/ASI6200_Manual_EN.pdf';
const _zwoAsi533Manual =
    'ZWO "ASI533 Manual" Rev 1.2, Aug 2021, sections 1 and 3 — '
    'https://i.zwoastro.com/zwo-website/manuals/ASI533_Manual_EN_V1.2.pdf';
const _zwoAsi533ProductPage =
    'ZWO product page "ASI533 Pro Series" specification table — '
    'https://www.zwoastro.com/product/asi533/';
const _zwoAsi294Manual =
    'ZWO "ASI294 Manual" Rev 2.2, Feb 2022, sections 3 and 4 — '
    'https://i.zwoastro.com/zwo-website/manuals/ASI294_Manual_EN_V2.2.pdf';
const _zwoAsi183Manual =
    'ZWO "ASI183 Manual" EN, sections 2, 4 and 5 — '
    'https://astronomy-imaging-camera.com/manuals/ASI183_Manual_EN.pdf';
const _qhy600Page =
    'QHYCCD product page "QHY600M/QHY600C" specification table — '
    'https://www.qhyccd.com/astronomical-camera-qhy600/';
const _qhy268Page =
    'QHYCCD product page "QHY268M/C PH (IMX571)" specification table — '
    'https://www.qhyccd.com/astronomical-camera-qhy268/';
const _qhy533Page =
    'QHYCCD product page "QHY533M & QHY533C" specification table — '
    'https://www.qhyccd.com/astronomical-camera-qhy533/';
const _qhy183Page =
    'QHYCCD product page "QHY183M & QHY183C" specification table — '
    'https://www.qhyccd.com/astronomical-camera-qhy183/';

/// The curated database.
///
/// Scope: the cooled astronomy cameras and astro-modified DSLRs this app's
/// users actually own. Each row's `driverNames` list is the complete match set
/// for that row — see [CameraSensorEntry.driverNames] for why there is no
/// fuzzy fallback.
///
/// Gain-dependent fields (read noise, full well) are stored in the shape the
/// manufacturer published them in, never flattened; see [PublishedFigure].
/// Where a manufacturer publishes no usable figure for a field the field is
/// empty and the resolver says the value is unknown for that camera, which is
/// the truth.
const List<CameraSensorEntry> kCuratedCameraSensors = [
  // ---------------------------------------------------------------- ZWO ASI
  //
  // The ASI1600 manual's model table lists ASI1600MM, ASI1600MM Pro and
  // ASI1600MM-Cool against one sensor part (MN34230ALJ) and one specification
  // table, so all three names are on this row. "ASI1600MM-Cool" is exactly
  // what the owner's driver reports.
  CameraSensorEntry(
    model: 'ZWO ASI1600MM',
    driverNames: ['ASI1600MM', 'ASI1600MM Pro', 'ASI1600MM-Cool'],
    sensor: 'Panasonic MN34230ALJ',
    widthPx: 4656,
    heightPx: 3520,
    publishedPixelSizeMicrons: 3.8,
    publishedImageAreaWidthMm: 17.6,
    publishedImageAreaHeightMm: 13.3,
    readNoiseE: [PublishedFigure.atLabel(1.2, label: '30 dB gain')],
    fullWellE: [PublishedFigure.unattributed(20000)],
    qePeakFraction: 0.60,
    source: _zwoAsi1600Manual,
    note:
        'ZWO quotes read noise only at 30 dB gain. The ASI1600 manual does not '
        'publish the mapping from dB to the driver gain value, so the figure '
        'is reported at the gain ZWO quoted it at rather than converted.',
  ),
  CameraSensorEntry(
    model: 'ZWO ASI1600MC',
    driverNames: ['ASI1600MC', 'ASI1600MC Pro', 'ASI1600MC-Cool'],
    sensor: 'Panasonic MN34230PLJ',
    widthPx: 4656,
    heightPx: 3520,
    publishedPixelSizeMicrons: 3.8,
    publishedImageAreaWidthMm: 17.6,
    publishedImageAreaHeightMm: 13.3,
    readNoiseE: [PublishedFigure.atLabel(1.2, label: '30 dB gain')],
    fullWellE: [PublishedFigure.unattributed(20000)],
    source: _zwoAsi1600Manual,
    note:
        'QE is omitted: section 5 of the manual gives a peak value only for '
        'the mono sensor and shows the colour sensor as a curve with no peak '
        'figure.',
  ),
  CameraSensorEntry(
    model: 'ZWO ASI2600MM Pro',
    driverNames: ['ASI2600MM Pro', 'ASI2600MM'],
    sensor: 'Sony IMX571',
    widthPx: 6248,
    heightPx: 4176,
    publishedPixelSizeMicrons: 3.76,
    publishedImageAreaWidthMm: 23.5,
    publishedImageAreaHeightMm: 15.7,
    readNoiseE: [PublishedFigure.range(low: 1.0, high: 3.3)],
    fullWellE: [PublishedFigure.unattributed(50000)],
    qePeakFraction: 0.91,
    source: _zwoAsi2600Manual,
  ),
  CameraSensorEntry(
    model: 'ZWO ASI2600MC Pro',
    driverNames: ['ASI2600MC Pro', 'ASI2600MC'],
    sensor: 'Sony IMX571',
    widthPx: 6248,
    heightPx: 4176,
    publishedPixelSizeMicrons: 3.76,
    publishedImageAreaWidthMm: 23.5,
    publishedImageAreaHeightMm: 15.7,
    readNoiseE: [PublishedFigure.range(low: 1.0, high: 3.3)],
    fullWellE: [PublishedFigure.unattributed(50000)],
    qePeakFraction: 0.80,
    source: _zwoAsi2600Manual,
    note:
        'ZWO publishes the colour QE peak as "above 80%", so 80% is a floor '
        'on the peak rather than the peak itself.',
  ),
  CameraSensorEntry(
    model: 'ZWO ASI6200MM Pro',
    driverNames: ['ASI6200MM Pro', 'ASI6200MM'],
    sensor: 'Sony IMX455',
    widthPx: 9576,
    heightPx: 6388,
    publishedPixelSizeMicrons: 3.76,
    publishedImageAreaWidthMm: 36.0,
    publishedImageAreaHeightMm: 24.0,
    // Section 4: "When the gain is 100, the HCG mode will be automatically
    // turned on. Additionally, the read noise is as low as 1.5e" — the one
    // place in the ZWO range where a read-noise figure is tied to a driver
    // gain value, so it is stored as such alongside the published range.
    readNoiseE: [
      PublishedFigure.atGain(1.5, gain: 100),
      PublishedFigure.range(low: 1.5, high: 3.5),
    ],
    fullWellE: [PublishedFigure.unattributed(51400)],
    qePeakFraction: 0.91,
    source: _zwoAsi6200Manual,
  ),
  CameraSensorEntry(
    model: 'ZWO ASI6200MC Pro',
    driverNames: ['ASI6200MC Pro', 'ASI6200MC'],
    sensor: 'Sony IMX455',
    widthPx: 9576,
    heightPx: 6388,
    publishedPixelSizeMicrons: 3.76,
    publishedImageAreaWidthMm: 36.0,
    publishedImageAreaHeightMm: 24.0,
    readNoiseE: [
      PublishedFigure.atGain(1.5, gain: 100),
      PublishedFigure.range(low: 1.5, high: 3.5),
    ],
    fullWellE: [PublishedFigure.unattributed(51400)],
    qePeakFraction: 0.91,
    source: _zwoAsi6200Manual,
    note:
        'The manual states the 91% peak QE for "the 6200 Sensor" without '
        'splitting mono from colour, so both rows carry it.',
  ),
  CameraSensorEntry(
    model: 'ZWO ASI533MC Pro',
    driverNames: ['ASI533MC Pro', 'ASI533MC'],
    sensor: 'Sony IMX533',
    widthPx: 3008,
    heightPx: 3008,
    publishedPixelSizeMicrons: 3.76,
    publishedImageAreaWidthMm: 11.31,
    publishedImageAreaHeightMm: 11.31,
    readNoiseE: [PublishedFigure.range(low: 1.0, high: 3.8)],
    fullWellE: [PublishedFigure.unattributed(50000)],
    qePeakFraction: 0.80,
    source: _zwoAsi533Manual,
  ),
  CameraSensorEntry(
    model: 'ZWO ASI533MM Pro',
    driverNames: ['ASI533MM Pro', 'ASI533MM'],
    sensor: 'Sony IMX533',
    widthPx: 3008,
    heightPx: 3008,
    publishedPixelSizeMicrons: 3.76,
    fullWellE: [PublishedFigure.unattributed(50000)],
    qePeakFraction: 0.91,
    source: _zwoAsi533ProductPage,
    note:
        'Read noise is omitted deliberately. The ASI533 manual covers only the '
        'MC Pro, and the product page gives the mono camera a single "1.0e-" '
        'with no gain, which is the best case at high gain — planning with it '
        'across the gain axis would understate noise by up to 3.8x.',
  ),
  CameraSensorEntry(
    model: 'ZWO ASI294MC Pro',
    driverNames: ['ASI294MC Pro', 'ASI294MC'],
    sensor: 'Sony IMX294',
    widthPx: 4144,
    heightPx: 2822,
    publishedPixelSizeMicrons: 4.63,
    publishedImageAreaWidthMm: 19.2,
    publishedImageAreaHeightMm: 13.0,
    // Section 4: "When the gain is 120, the HCG mode will be automatically
    // turned on. Additionally, the read noise is as low as 1.2e".
    readNoiseE: [
      PublishedFigure.atGain(1.2, gain: 120),
      PublishedFigure.range(low: 1.2, high: 7.3),
    ],
    fullWellE: [PublishedFigure.unattributed(63700)],
    qePeakFraction: 0.75,
    source: _zwoAsi294Manual,
  ),
  CameraSensorEntry(
    model: 'ZWO ASI294MM Pro',
    driverNames: ['ASI294MM Pro', 'ASI294MM'],
    sensor: 'Sony IMX492',
    widthPx: 4144,
    heightPx: 2822,
    publishedPixelSizeMicrons: 4.63,
    publishedImageAreaWidthMm: 19.2,
    publishedImageAreaHeightMm: 13.0,
    readNoiseE: [
      PublishedFigure.atGain(1.2, gain: 120),
      PublishedFigure.range(low: 1.2, high: 8.0),
    ],
    fullWellE: [PublishedFigure.unattributed(66400)],
    qePeakFraction: 0.90,
    source: _zwoAsi294Manual,
    note:
        'These are the camera\'s default mode figures, which is how ZWO\'s '
        'specification table states them. The IMX492 also has an "unlocked '
        'bin 1" mode at a finer pitch that this row does not describe; when '
        'the camera is connected the driver reports the mode actually in use, '
        'and that reading wins over this row.',
  ),
  CameraSensorEntry(
    model: 'ZWO ASI183MM',
    driverNames: ['ASI183MM', 'ASI183MM Pro'],
    sensor: 'Sony IMX183CLK-J',
    widthPx: 5496,
    heightPx: 3672,
    publishedPixelSizeMicrons: 2.4,
    publishedImageAreaWidthMm: 13.2,
    publishedImageAreaHeightMm: 8.8,
    readNoiseE: [PublishedFigure.atLabel(1.6, label: '30 dB gain')],
    fullWellE: [PublishedFigure.unattributed(15000)],
    qePeakFraction: 0.84,
    source: _zwoAsi183Manual,
  ),
  CameraSensorEntry(
    model: 'ZWO ASI183MC',
    driverNames: ['ASI183MC', 'ASI183MC Pro'],
    sensor: 'Sony IMX183CQJ-J',
    widthPx: 5496,
    heightPx: 3672,
    publishedPixelSizeMicrons: 2.4,
    publishedImageAreaWidthMm: 13.2,
    publishedImageAreaHeightMm: 8.8,
    readNoiseE: [PublishedFigure.atLabel(1.6, label: '30 dB gain')],
    fullWellE: [PublishedFigure.unattributed(15000)],
    source: _zwoAsi183Manual,
    note: 'QE is omitted: section 5 gives a peak only for the mono sensor.',
  ),

  // -------------------------------------------------------------------- QHY
  //
  // QHY crops the same Sony parts differently from ZWO — QHY's IMX571 rows are
  // 6252x4176 against ZWO's 6248x4176, and QHY's IMX183 is 5544x3684 against
  // ZWO's 5496x3672 — so the vendors get separate rows rather than aliases on
  // one. QHY's specification tables carry no peak QE figure, only QE curve
  // graphics, so `qePeakFraction` is null on every QHY row.
  CameraSensorEntry(
    model: 'QHY600M',
    driverNames: ['QHY600M', 'QHY600M-PH', 'QHY600M PH'],
    sensor: 'Sony IMX455',
    widthPx: 9576,
    heightPx: 6388,
    publishedPixelSizeMicrons: 3.76,
    readNoiseE: [PublishedFigure.range(low: 1.0, high: 3.7)],
    fullWellE: [PublishedFigure.unattributed(51000)],
    source: _qhy600Page,
    note:
        'Standard-mode figures at 1x1 binning. QHY publishes full well as '
        '">51ke-" in standard mode and ">80ke-" in Super Full Well mode; the '
        'standard-mode floor is the conservative one and is what this row '
        'carries.',
  ),
  CameraSensorEntry(
    model: 'QHY600C',
    driverNames: ['QHY600C', 'QHY600C-PH', 'QHY600C PH'],
    sensor: 'Sony IMX455',
    widthPx: 9576,
    heightPx: 6388,
    publishedPixelSizeMicrons: 3.76,
    readNoiseE: [PublishedFigure.range(low: 1.0, high: 3.7)],
    fullWellE: [PublishedFigure.unattributed(51000)],
    source: _qhy600Page,
    note: 'Standard-mode figures at 1x1 binning.',
  ),
  CameraSensorEntry(
    model: 'QHY268M',
    driverNames: ['QHY268M', 'QHY268M-PH', 'QHY268M PH'],
    sensor: 'Sony IMX571',
    widthPx: 6252,
    heightPx: 4176,
    publishedPixelSizeMicrons: 3.76,
    readNoiseE: [PublishedFigure.range(low: 1.1, high: 3.5)],
    fullWellE: [PublishedFigure.unattributed(51000)],
    source: _qhy268Page,
    note:
        'Standard-mode figures. QHY also publishes an Extended Full Well mode '
        'at 80ke- whose read noise is 5.3-7.4e-; those are a different '
        'operating mode, not a different gain, so they are not blended in.',
  ),
  CameraSensorEntry(
    model: 'QHY268C',
    driverNames: ['QHY268C', 'QHY268C-PH', 'QHY268C PH'],
    sensor: 'Sony IMX571',
    widthPx: 6252,
    heightPx: 4176,
    publishedPixelSizeMicrons: 3.76,
    readNoiseE: [PublishedFigure.range(low: 1.1, high: 3.5)],
    fullWellE: [PublishedFigure.unattributed(51000)],
    source: _qhy268Page,
    note: 'Standard-mode figures.',
  ),
  CameraSensorEntry(
    model: 'QHY533M',
    driverNames: ['QHY533M'],
    sensor: 'Sony IMX533',
    widthPx: 3008,
    heightPx: 3008,
    publishedPixelSizeMicrons: 3.76,
    readNoiseE: [PublishedFigure.range(low: 1.3, high: 3.4)],
    fullWellE: [PublishedFigure.unattributed(58000)],
    source: _qhy533Page,
    note:
        'Effective pixel area. QHY additionally quotes 3008x3028 including the '
        'optical black and overscan rows, which are not part of the image.',
  ),
  CameraSensorEntry(
    model: 'QHY533C',
    driverNames: ['QHY533C'],
    sensor: 'Sony IMX533',
    widthPx: 3008,
    heightPx: 3008,
    publishedPixelSizeMicrons: 3.76,
    readNoiseE: [PublishedFigure.range(low: 1.3, high: 3.4)],
    fullWellE: [PublishedFigure.unattributed(58000)],
    source: _qhy533Page,
    note: 'Effective pixel area, excluding optical black and overscan.',
  ),
  CameraSensorEntry(
    model: 'QHY183M',
    driverNames: ['QHY183M'],
    sensor: 'Sony IMX183',
    widthPx: 5544,
    heightPx: 3684,
    publishedPixelSizeMicrons: 2.4,
    readNoiseE: [PublishedFigure.range(low: 1.0, high: 2.7)],
    fullWellE: [PublishedFigure.unattributed(15500)],
    source: _qhy183Page,
    note:
        'QHY publishes the read-noise ends as "2.7e- at lowest gain" and '
        '"1.0e- at high gain" without naming the driver gains, so they are '
        'stored as the published range.',
  ),
  CameraSensorEntry(
    model: 'QHY183C',
    driverNames: ['QHY183C'],
    sensor: 'Sony IMX183',
    widthPx: 5544,
    heightPx: 3684,
    publishedPixelSizeMicrons: 2.4,
    readNoiseE: [PublishedFigure.range(low: 1.0, high: 2.7)],
    fullWellE: [PublishedFigure.unattributed(15500)],
    source: _qhy183Page,
    note: 'Read-noise ends published as "at lowest gain" / "at high gain".',
  ),

  // ------------------------------------------------------------------ DSLRs
  //
  // Canon and Nikon publish the imaging area in millimetres and the pixel
  // count, but never read noise, full well or QE. Those three fields are
  // therefore absent from every DSLR row: the planner is told the pitch and
  // the geometry, and told plainly that the rest is not published.
  //
  // Pixel pitch is derived from the two published numbers rather than stored,
  // so what sits in this file stays exactly what the manufacturer printed.
  // Canon rounds the imaging area to 0.1 mm (and to whole millimetres on some
  // bodies), which puts the derived pitch within about 0.6% of the figure
  // reviewers measure — an image-scale error well under a tenth of a pixel
  // across a full frame, and the provenance line says the pitch is derived.
  CameraSensorEntry(
    model: 'Canon EOS 6D',
    driverNames: ['Canon EOS 6D', 'EOS 6D'],
    sensor: 'Canon CMOS (full frame)',
    widthPx: 5472,
    heightPx: 3648,
    publishedImageAreaWidthMm: 36.0,
    publishedImageAreaHeightMm: 24.0,
    source:
        'Canon EOS 6D specifications, Image Sensor and Image Size — '
        'https://www.canon.co.uk/for_home/product_finder/cameras/digital_slr/'
        'eos_6d/specifications/',
  ),
  CameraSensorEntry(
    model: 'Canon EOS 6D Mark II',
    driverNames: ['Canon EOS 6D Mark II', 'EOS 6D Mark II'],
    sensor: 'Canon CMOS (full frame)',
    widthPx: 6240,
    heightPx: 4160,
    publishedImageAreaWidthMm: 35.9,
    publishedImageAreaHeightMm: 24.0,
    source:
        'Canon EOS 6D Mark II specifications, Image Sensor and Image Size — '
        'https://www.canon.co.uk/cameras/eos-6d-mark-ii/specifications/',
  ),
  CameraSensorEntry(
    model: 'Canon EOS Ra',
    driverNames: ['Canon EOS Ra', 'EOS Ra'],
    sensor: 'Canon CMOS (full frame)',
    widthPx: 6720,
    heightPx: 4480,
    publishedImageAreaWidthMm: 36.0,
    publishedImageAreaHeightMm: 24.0,
    source:
        'Canon EOS Ra specifications, Image Sensor and Image Size — '
        'https://www.canon.co.uk/cameras/eos-ra/specifications/',
  ),
  CameraSensorEntry(
    model: 'Canon EOS R6',
    driverNames: ['Canon EOS R6', 'EOS R6'],
    sensor: 'Canon CMOS (full frame)',
    widthPx: 5472,
    heightPx: 3648,
    publishedImageAreaWidthMm: 35.9,
    publishedImageAreaHeightMm: 23.9,
    source:
        'Canon EOS R6 specifications, Image Sensor and Image Size — '
        'https://www.canon.co.uk/cameras/eos-r6/specifications/',
  ),
  CameraSensorEntry(
    model: 'Canon EOS 60Da',
    driverNames: ['Canon EOS 60Da', 'EOS 60Da'],
    sensor: 'Canon CMOS (APS-C)',
    widthPx: 5184,
    heightPx: 3456,
    publishedImageAreaWidthMm: 22.3,
    publishedImageAreaHeightMm: 14.9,
    source:
        'Canon EOS 60Da specifications, Image Sensor and Image Size — '
        'https://www.canon.co.uk/for_home/product_finder/cameras/digital_slr/'
        'eos_60da/specifications/',
  ),
  CameraSensorEntry(
    model: 'Canon EOS 600D',
    driverNames: [
      'Canon EOS 600D',
      'EOS 600D',
      'Canon EOS Rebel T3i',
      'EOS Rebel T3i',
    ],
    sensor: 'Canon CMOS (APS-C)',
    widthPx: 5184,
    heightPx: 3456,
    publishedImageAreaWidthMm: 22.3,
    publishedImageAreaHeightMm: 14.9,
    source:
        'Canon EOS 600D specifications, Image Sensor and Image Size — '
        'https://www.canon.co.uk/for_home/product_finder/cameras/digital_slr/'
        'eos_600d/specifications/',
    note:
        'Canon sells this body as the EOS 600D outside North America and as '
        'the EOS Rebel T3i inside it; both names are on this row.',
  ),
  CameraSensorEntry(
    model: 'Nikon D5300',
    driverNames: ['Nikon D5300', 'D5300'],
    sensor: 'Nikon DX-format CMOS',
    widthPx: 6000,
    heightPx: 4000,
    publishedImageAreaWidthMm: 23.5,
    publishedImageAreaHeightMm: 15.6,
    source:
        'Nikon D5300 specifications, 撮像素子 and 記録画素数 — '
        'https://nij.nikon.com/products/lineup/slr/d5300/spec.html',
  ),
  CameraSensorEntry(
    model: 'Nikon D750',
    driverNames: ['Nikon D750', 'D750'],
    sensor: 'Nikon FX-format CMOS',
    widthPx: 6016,
    heightPx: 4016,
    publishedImageAreaWidthMm: 35.9,
    publishedImageAreaHeightMm: 24.0,
    source:
        'Nikon D750 specifications, 撮像素子 and 記録画素数 (FX, size L) — '
        'https://nij.nikon.com/products/lineup/slr/d750/spec.html',
  ),
  CameraSensorEntry(
    model: 'Nikon D810A',
    driverNames: ['Nikon D810A', 'D810A'],
    sensor: 'Nikon FX-format CMOS',
    widthPx: 7360,
    heightPx: 4912,
    publishedImageAreaWidthMm: 35.9,
    publishedImageAreaHeightMm: 24.0,
    source:
        'Nikon D810A specifications, 撮像素子 and 記録画素数 (FX, size L) — '
        'https://nij.nikon.com/products/lineup/slr/d810a/spec.html',
  ),
];
