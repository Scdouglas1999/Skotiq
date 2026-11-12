part of '../tour.dart';

// The first-night walkthrough, replayed from Settings > Help.
//
// Step descriptions are intentionally 80–150 words each: they teach why each
// phase of a night exists, not just where to click. A new astrophotographer
// should be able to finish the walkthrough and have a sequence running without
// consulting external docs.
const List<TourStep> _firstNight = [
  TourStep(
    id: 'fn_welcome',
    icon: SkotiqIcons.sparkle,
    title: 'Welcome to your first night',
    // WHY: First-time astrophotographers usually have a "minimum gear list"
    // they assembled from a forum thread but no idea what order to use it
    // in. This step sets that order in stone before they get lost clicking.
    description:
        'A clean imaging night runs roughly the same way every time: connect '
        'your equipment, polar-align the mount, cool the camera and focus, '
        'frame the target, start the autoguider, then launch a sequence. '
        'This wizard walks you through each phase with a short explanation '
        'of why it matters and a button that jumps you straight to the '
        'right screen. Before we start, make sure you have at least a '
        'camera, a mount, a focuser, and a filter wheel ready (a filter '
        'wheel is optional for one-shot color cameras). You can skip any '
        'step or close the wizard at any time — your progress is saved, so '
        'you can pick up where you left off on the next launch.',
  ),
  TourStep(
    id: 'fn_connect_equipment',
    icon: SkotiqIcons.connected,
    showMe: AppRoute.equipment,
    title: '1. Connect your equipment',
    // WHY: Connection failures are the #1 source of "Skotiq is broken"
    // posts on Cloudy Nights. The user needs to understand that profiles
    // exist, that driver choice (ASCOM vs INDI vs native) matters, and
    // that nothing else will work until devices are green.
    description:
        'Open the Equipment screen and pick or create a profile — a profile '
        'is just a saved bundle of "which camera, which mount, which '
        'focuser" that you can reuse every night. For each device, pick a '
        'driver: ASCOM works on Windows, INDI works on Linux/macOS, and '
        'Alpaca works over a network. Native vendor paths (ZWO, QHY, '
        'PlayerOne, Touptek, …) cut out the driver layer, but only work '
        'where that vendor\'s own library is installed — Skotiq does not '
        'ship it. Click Connect on every device until '
        'the status dots are all green. If a device fails to connect, the '
        'error message in the side panel will tell you why — usually it\'s '
        'a USB cable, a driver not installed, or the device powered off. '
        'Nothing else in this wizard works until everything here is green.',
  ),
  TourStep(
    id: 'fn_polar_align',
    icon: SkotiqIcons.compass,
    showMe: AppRoute.polarAlignment,
    title: '2. Polar-align the mount',
    // WHY: Beginners skip polar alignment because it looks fiddly, then
    // wonder why their 5-minute exposures have field rotation. Explain the
    // two methods, when each applies, and acceptable error so they know
    // when "good enough" really is good enough.
    description:
        'Polar alignment lines up the mount\'s rotation axis with the '
        'celestial pole. Without it, stars trail in long exposures and the '
        'frame slowly rotates around the guide star — guiding can\'t fix '
        'either. Skotiq ships two methods. Drift alignment is the most '
        'accurate but slow: it watches a star drift over minutes and tells '
        'you which knob to turn. Plate-solve alignment is fast: it takes '
        'three exposures at different mount angles, solves them, and '
        'computes the polar error directly. Use plate-solve for nightly '
        'setups, drift for permanent piers. Visual observing tolerates 5–10 '
        'arcminutes of error; for imaging aim for under 1 arcminute. The '
        'wizard on the Polar Alignment screen walks you through whichever '
        'method you pick.',
  ),
  TourStep(
    id: 'fn_cool_and_focus',
    icon: SkotiqIcons.frost,
    showMe: AppRoute.imaging,
    title: '3. Cool the camera, then focus',
    // WHY: The order matters — focusing on a warm sensor gives you a HFR
    // that drifts as the sensor cools and contracts. Beginners do this in
    // the wrong order constantly.
    description:
        'A cooled camera has dramatically lower thermal noise, which is the '
        'difference between a clean star field and a grainy mess. Set your '
        'target sensor temperature in the Imaging screen — most cooled '
        'astro cameras hit -10 °C year-round; in summer aim for whatever '
        'is reliably 30 °C below ambient. Wait for the cooler to settle '
        '(power should drop below ~80 %) before you focus, because the '
        'sensor physically shrinks as it cools and your focus point '
        'shifts. Then run autofocus: Skotiq samples the half-flux '
        'radius (HFR) of stars at several focuser positions, fits a V-curve '
        'or hyperbola, and parks the focuser at the minimum. Good focus is '
        'the single biggest visual improvement you can make to your images.',
  ),
  TourStep(
    id: 'fn_frame_target',
    icon: LucideIcons.crop,
    showMe: AppRoute.framing,
    title: '4. Frame your target',
    // WHY: New imagers point at the wrong DSO, or get the rotation wrong,
    // and waste hours of data. Pre-framing on the planetarium catches this.
    description:
        'The Framing screen overlays your camera\'s field of view on a '
        'survey image of the sky so you can preview exactly what each '
        'exposure will look like before you slew. Pick a beginner-friendly '
        'target — the Orion Nebula (M42), the Andromeda Galaxy (M31), or '
        'the Pleiades (M45) are bright, large, and forgiving of imperfect '
        'tracking. Drag the FOV rectangle to center your target, rotate it '
        'to a pleasing composition, and click "Slew & Center". Skotiq '
        'will slew the mount, take a plate-solve exposure, compute the '
        'pointing error, and nudge the mount until the target lands inside '
        'a few arcseconds of where you placed it. This pre-flight step is '
        'what separates a wasted slew from a usable sequence.',
  ),
  TourStep(
    id: 'fn_start_guiding',
    icon: SkotiqIcons.crosshair,
    showMe: AppRoute.guiding,
    title: '5. Start the autoguider',
    // WHY: Beginners often try to image without guiding "to keep things
    // simple" and then can\'t figure out why their 3-minute subs are all
    // egg-shaped. PHD2 is the de-facto standard so we say so.
    description:
        'Even a well-aligned mount drifts a few arcseconds per minute from '
        'periodic gear error, atmospheric refraction, and small alignment '
        'residuals. The autoguider locks onto a second star, measures that '
        'drift in real time, and sends correction pulses to the mount. '
        'Skotiq guides with its built-in multi-star guider or with PHD2, '
        'the open-source guider, whichever your profile uses. On the '
        'Guiding screen, connect the guider (PHD2 must already be running '
        'and connected to your guide camera and mount), pick a guide star, '
        'and start guiding. Watch '
        'the RMS graph: under 1 arcsecond total is excellent, 1–2 is fine '
        'for most cameras, and over 3 arcseconds means your alignment, '
        'balance, or guide calibration needs another pass before you '
        'commit to long exposures.',
  ),
  TourStep(
    id: 'fn_start_sequence',
    icon: SkotiqIcons.play,
    showMe: AppRoute.sequencer,
    title: '6. Launch the sequence',
    // WHY: This is the payoff step — once a sequence is running, the
    // user goes inside and sleeps. The sample sequence concept is the
    // hand-hold that keeps them from staring at the empty sequencer.
    description:
        'A sequence is the script that tells Skotiq what to capture, '
        'when to dither, when to refocus, and when to flip across the '
        'meridian. The Sequencer screen builds these as a tree of '
        'instruction, trigger, and logic nodes — but for tonight, open the '
        'Templates tab and load a ready-made one ("Basic LRGB Sequence" and '
        '"Narrowband (SHO)" both come with autofocus and dithering already '
        'wired in), set the target, and '
        'click Start. While it runs, the trigger nodes watch HFR, guiding, '
        'and time on their own: they refocus, flip, or recover when needed, '
        'and tell you when quality drifts out of tolerance while the run '
        'keeps imaging. That\'s the whole point: you '
        'set this up at the start of the night, walk away, and come back '
        'to a stack of calibrated frames at dawn. Welcome to '
        'astrophotography.',
  ),
];

