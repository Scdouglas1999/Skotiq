// First-night onboarding and workflow tutorial definitions.
part of '../tutorial_models.dart';

// First night wizard (7 steps)
//
// The full new-user walkthrough — fires on first launch when no tutorial
// progress exists. Unlike the existing in-app overlay tours, each step is
// a modal SkotiqDialog with WHY-style guidance (why polar alignment
// matters, why guiding helps, etc.) and a "Show me" deep-link button that
// navigates to the relevant screen so the user can perform the action and
// come back. Persisted to `tutorial_progress` so users can resume mid-way.
//
// Step descriptions are intentionally 80–150 words each — they teach
// WHY each phase exists, not just where to click. A new astrophotographer
// launching Skotiq should be able to finish the wizard and have a
// sequence running without consulting external docs.
const List<TutorialStep> _firstNight = [
  TutorialStep(
    id: 'fn_welcome',
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
    position: TooltipPosition.center,
    order: 0,
    category: TutorialCategory.firstNight,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'fn_connect_equipment',
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
    action: 'Show me',
    position: TooltipPosition.center,
    order: 1,
    category: TutorialCategory.firstNight,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'fn_polar_align',
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
    action: 'Show me',
    position: TooltipPosition.center,
    order: 2,
    category: TutorialCategory.firstNight,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'fn_cool_and_focus',
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
    action: 'Show me',
    position: TooltipPosition.center,
    order: 3,
    category: TutorialCategory.firstNight,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'fn_frame_target',
    title: '4. Frame your target',
    // WHY: New imagers point at the wrong DSO, or get the rotation wrong,
    // and waste hours of data. Pre-framing on the planetarium catches this.
    description:
        'The Framing screen overlays your camera\'s field of view on a '
        'survey image of the sky so you can preview exactly what each '
        'exposure will look like before you slew. Pick a beginner-friendly '
        'target — the Orion Nebula (M42), the Andromeda Galaxy (M31), or '
        'the Pleiades (M45) are bright, large, and forgiving of imperfect '
        'tracking. Drag the FOV rectangle to centre your target, rotate it '
        'to a pleasing composition, and click "Slew & Center". Skotiq '
        'will slew the mount, take a plate-solve exposure, compute the '
        'pointing error, and nudge the mount until the target lands inside '
        'a few arcseconds of where you placed it. This pre-flight step is '
        'what separates a wasted slew from a usable sequence.',
    action: 'Show me',
    position: TooltipPosition.center,
    order: 4,
    category: TutorialCategory.firstNight,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'fn_start_guiding',
    title: '5. Start the autoguider',
    // WHY: Beginners often try to image without guiding "to keep things
    // simple" and then can\'t figure out why their 3-minute subs are all
    // egg-shaped. PHD2 is the de-facto standard so we say so.
    description:
        'Even a well-aligned mount drifts a few arcseconds per minute from '
        'periodic gear error, atmospheric refraction, and small alignment '
        'residuals. The autoguider locks onto a second star, measures that '
        'drift in real time, and sends correction pulses to the mount. '
        'Skotiq controls PHD2 — the standard open-source guider — '
        'over its event/server protocol. Connect to PHD2 on the Guiding '
        'screen (it must already be running and connected to your guide '
        'camera and mount), pick a guide star, and start guiding. Watch '
        'the RMS graph: under 1 arcsecond total is excellent, 1–2 is fine '
        'for most cameras, and over 3 arcseconds means your alignment, '
        'balance, or guide calibration needs another pass before you '
        'commit to long exposures.',
    action: 'Show me',
    position: TooltipPosition.center,
    order: 5,
    category: TutorialCategory.firstNight,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'fn_start_sequence',
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
        'and time on their own — they\'ll pause, refocus, or recover if '
        'something drifts out of tolerance. That\'s the whole point: you '
        'set this up at the start of the night, walk away, and come back '
        'to a stack of calibrated frames at dawn. Welcome to '
        'astrophotography.',
    action: 'Show me',
    position: TooltipPosition.center,
    order: 6,
    category: TutorialCategory.firstNight,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// First light tour (5 steps)
// Connect -> Expose -> View
const List<TutorialStep> _firstLight = [
  TutorialStep(
    id: 'fl_welcome',
    title: 'Welcome to Skotiq',
    description:
        'Let\'s capture your first image! In this quick tour, you\'ll connect your camera, take a snapshot, and view the result. Click Next to begin.',
    position: TooltipPosition.center,
    order: 0,
    category: TutorialCategory.firstLight,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'fl_navigate_equipment',
    title: 'Navigate to Equipment',
    description:
        'Click the Equipment tab in the sidebar to access device connections. This is where you\'ll connect your camera.',
    targetKey: 'nav_equipment',
    position: TooltipPosition.right,
    order: 1,
    category: TutorialCategory.firstLight,
    requiredAction: 'click',
    actionTarget: 'nav_equipment',
    isInteractive: true,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'fl_connect_camera',
    title: 'Connect your camera',
    description:
        'Select your camera from the dropdown and click the Connect button. Once connected, the status indicator will turn green.',
    targetKey: 'camera_connect_button',
    position: TooltipPosition.bottom,
    order: 2,
    category: TutorialCategory.firstLight,
    requiredAction: 'click',
    actionTarget: 'camera_connect_button',
    isInteractive: true,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'fl_take_snapshot',
    title: 'Take a snapshot',
    description:
        'Navigate to the Imaging tab and click the Snapshot button to capture a single frame. Adjust exposure time if needed before capturing.',
    targetKey: 'snapshot_button',
    position: TooltipPosition.top,
    order: 3,
    category: TutorialCategory.firstLight,
    requiredAction: 'click',
    actionTarget: 'snapshot_button',
    isInteractive: true,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'fl_success',
    title: 'Congratulations!',
    description:
        'You\'ve captured your first image with Skotiq! Your image appears in the preview area. Explore the other tours to learn about automated imaging, target planning, and more.',
    position: TooltipPosition.center,
    order: 4,
    category: TutorialCategory.firstLight,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// Equipment setup tour (4 steps)
// Profiles -> Drivers -> Connect
// Each step names a control that exists on the Equipment screen (a Profiles
// side panel with a + button, per-device cards) and a targetKey some widget
// registers — a key nothing registers spotlights nothing.
const List<TutorialStep> _equipmentSetup = [
  TutorialStep(
    id: 'eq_profiles_overview',
    title: 'Equipment profiles',
    description:
        'The Profiles panel lists your equipment configurations. A profile saves one telescope, camera and accessory combination, so you can switch rigs without re-entering anything.',
    targetKey: 'equipment_profile_selector',
    position: TooltipPosition.right,
    order: 0,
    category: TutorialCategory.equipmentSetup,
    isInteractive: true,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'eq_create_profile',
    title: 'Create a profile',
    description:
        'The + button at the top of the Profiles panel opens a new configuration. Enter focal length, aperture and your camera details — those are what the field-of-view and pixel-scale figures are computed from.',
    targetKey: 'equipment_create_profile_btn',
    position: TooltipPosition.bottom,
    order: 1,
    category: TutorialCategory.equipmentSetup,
    requiredAction: 'click',
    actionTarget: 'equipment_create_profile_btn',
    isInteractive: true,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'eq_connect_devices',
    title: 'Connect devices',
    description:
        'Connect All brings up every device in the selected profile. Use ASCOM COM only on Windows, Alpaca for ASCOM network devices, INDI through a reachable server, and Native only where the release includes the needed SDK.',
    targetKey: 'equipment_quick_connect_bar',
    position: TooltipPosition.top,
    order: 2,
    category: TutorialCategory.equipmentSetup,
    requiredAction: 'click',
    actionTarget: 'equipment_quick_connect_bar',
    isInteractive: true,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'eq_verify_status',
    title: 'Verify connections',
    description:
        'Each connected device gets a card here. Green means connected and ready; a device that failed to connect reports the error on the card instead.',
    targetKey: 'equipment_camera_card',
    position: TooltipPosition.left,
    order: 3,
    category: TutorialCategory.equipmentSetup,
    isInteractive: false,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// Target planning tour (4 steps)
// Planetarium -> Search -> Slew -> Frame
const List<TutorialStep> _targetPlanning = [
  TutorialStep(
    id: 'tp_planetarium',
    title: 'Open the Planetarium',
    description:
        'Click the Planetarium tab to access the interactive sky chart. This shows your current sky with all visible objects based on your location and time.',
    targetKey: 'nav_planetarium',
    position: TooltipPosition.right,
    order: 0,
    category: TutorialCategory.targetPlanning,
    requiredAction: 'click',
    actionTarget: 'nav_planetarium',
    isInteractive: true,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'tp_search',
    title: 'Search for objects',
    description:
        'Click the search bar and type an object name (like M31, NGC 7000, or Vega). Select from the results to center the planetarium on that object.',
    targetKey: 'planetarium_search',
    position: TooltipPosition.bottom,
    order: 1,
    category: TutorialCategory.targetPlanning,
    requiredAction: 'input',
    actionTarget: 'planetarium_search',
    isInteractive: true,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'tp_slew',
    title: 'Slew to target',
    description:
        'Right-click the object and select "Slew Here" to point your mount at the target. Ensure your mount is connected before slewing.',
    targetKey: 'slew_button',
    position: TooltipPosition.bottom,
    order: 2,
    category: TutorialCategory.targetPlanning,
    requiredAction: 'click',
    actionTarget: 'slew_button',
    isInteractive: true,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'tp_framing',
    title: 'Frame your shot',
    description:
        'Navigate to the Framing tab to compose your image. Drag and rotate the field-of-view rectangle to find the perfect composition before imaging.',
    targetKey: 'nav_framing',
    position: TooltipPosition.right,
    order: 3,
    category: TutorialCategory.targetPlanning,
    requiredAction: 'click',
    actionTarget: 'nav_framing',
    isInteractive: true,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// Automated imaging tour (5 steps)
// Sequencer basics -> Build -> Run
const List<TutorialStep> _automatedImaging = [
  TutorialStep(
    id: 'ai_sequencer_intro',
    title: 'Meet the Sequencer',
    description:
        'Click the Sequencer tab to access automated imaging. The Sequencer runs your imaging plan unattended, handling slews, exposures, autofocus, and more.',
    targetKey: 'nav_sequencer',
    position: TooltipPosition.right,
    order: 0,
    category: TutorialCategory.automatedImaging,
    requiredAction: 'click',
    actionTarget: 'nav_sequencer',
    isInteractive: true,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'ai_add_blocks',
    title: 'Add sequence blocks',
    description:
        'Drag blocks from the left palette onto the canvas. Start with a Target Group block, then add Capture blocks for your exposures. Each block configures one part of your workflow.',
    targetKey: 'sequence_palette',
    position: TooltipPosition.right,
    order: 1,
    category: TutorialCategory.automatedImaging,
    isInteractive: true,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'ai_configure',
    title: 'Configure capture settings',
    description:
        'Click a Capture block to configure it. Set the filter, exposure time, gain, and number of frames. Add multiple Capture blocks for different filters (LRGB, narrowband).',
    targetKey: 'capture_block_config',
    position: TooltipPosition.left,
    order: 2,
    category: TutorialCategory.automatedImaging,
    requiredAction: 'click',
    actionTarget: 'capture_block_config',
    isInteractive: true,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'ai_run',
    title: 'Run the sequence',
    description:
        'Click the Play button to start your sequence. Skotiq will execute each block in order, automatically handling equipment control and image saving.',
    targetKey: 'sequence_play_button',
    position: TooltipPosition.bottom,
    order: 3,
    category: TutorialCategory.automatedImaging,
    requiredAction: 'click',
    actionTarget: 'sequence_play_button',
    isInteractive: true,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'ai_monitor',
    title: 'Monitor progress',
    description:
        'Watch the progress panel as your sequence runs. Green checkmarks indicate completed blocks. Click Pause to interrupt, or Stop to end the session. Images save automatically.',
    targetKey: 'sequence_progress_panel',
    position: TooltipPosition.left,
    order: 4,
    category: TutorialCategory.automatedImaging,
    isInteractive: false,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// Calibration frames tour (3 steps)
// Flat wizard workflow
const List<TutorialStep> _calibrationFrames = [
  TutorialStep(
    id: 'cf_what_are_flats',
    title: 'What are flat frames?',
    description:
        'Flat frames correct for vignetting and dust spots in your optical system. Navigate to the Flat Wizard tab to capture them easily.',
    targetKey: 'nav_flat_wizard',
    position: TooltipPosition.right,
    order: 0,
    category: TutorialCategory.calibrationFrames,
    requiredAction: 'click',
    actionTarget: 'nav_flat_wizard',
    isInteractive: true,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'cf_wizard_setup',
    title: 'Configure the wizard',
    description:
        'Select your flat source (sky flats, light panel, or EL panel). Set the target ADU level (typically 50% of your camera\'s well depth). The wizard will calculate exposure times automatically.',
    targetKey: 'flat_wizard_config',
    position: TooltipPosition.left,
    order: 1,
    category: TutorialCategory.calibrationFrames,
    isInteractive: true,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'cf_capture_flats',
    title: 'Capture flat frames',
    description:
        'Click Start to begin capturing. The wizard takes test exposures, adjusts timing, then captures your specified number of flats per filter. Watch the ADU histogram to verify exposure.',
    targetKey: 'flat_wizard_start',
    position: TooltipPosition.top,
    order: 2,
    category: TutorialCategory.calibrationFrames,
    requiredAction: 'click',
    actionTarget: 'flat_wizard_start',
    isInteractive: true,
    spotlightShape: SpotlightShape.circle,
  ),
];

// Advanced features tour (4 steps)
// Analytics, weather, history, settings
const List<TutorialStep> _advancedFeatures = [
  TutorialStep(
    id: 'af_analytics',
    title: 'Session Analytics',
    description:
        'Click the Analytics tab to review your imaging performance. View HFR trends, guiding accuracy, and sky conditions over time to identify areas for improvement.',
    targetKey: 'nav_analytics',
    position: TooltipPosition.right,
    order: 0,
    category: TutorialCategory.advancedFeatures,
    requiredAction: 'click',
    actionTarget: 'nav_analytics',
    isInteractive: true,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'af_weather',
    title: 'Weather integration',
    description:
        'Check the weather widget on the Dashboard for current conditions. Configure alerts in Settings to pause imaging when clouds approach or humidity rises.',
    targetKey: 'weather_widget',
    position: TooltipPosition.left,
    order: 1,
    category: TutorialCategory.advancedFeatures,
    isInteractive: false,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'af_history',
    title: 'Session history',
    description:
        'Click the History tab in Analytics to browse past sessions. Review captured frames, total integration time, and conditions for each imaging night.',
    targetKey: 'history_tab',
    position: TooltipPosition.bottom,
    order: 2,
    category: TutorialCategory.advancedFeatures,
    requiredAction: 'click',
    actionTarget: 'history_tab',
    isInteractive: true,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'af_settings',
    title: 'Customize settings',
    description:
        'Click the Settings icon in the title bar to configure your location, file paths, plate solving, and other preferences. Set your coordinates for accurate sky calculations.',
    targetKey: 'settings_button',
    position: TooltipPosition.bottom,
    order: 3,
    category: TutorialCategory.advancedFeatures,
    requiredAction: 'click',
    actionTarget: 'settings_button',
    isInteractive: true,
    spotlightShape: SpotlightShape.circle,
  ),
];
