part of '../tour.dart';

// Where the main places are. Replayed from Settings > Help.
const List<TourStep> _firstLaunchTour = [
  TourStep(
    id: 'welcome',
    title: 'Welcome to Skotiq',
    description: 'Skotiq is your imaging assistant. Three things to set up '
        'first: equipment, a profile, and a sequence. The next few '
        'steps will show you where each lives.',
  ),
  TourStep(
    id: 'equipment',
    title: 'Connect your gear',
    // Scoped to what the support matrix in README.md claims: the native paths
    // need vendor libraries the installer does not redistribute.
    description: 'Connect your camera, mount, and filter wheel here. ASCOM '
        '(Windows), INDI, and Alpaca work against drivers you already '
        'have. Native vendor paths (ZWO, QHY, Player One, SVBony, Atik, '
        'FLI, Moravian, Touptek) need that vendor\'s own library '
        'installed — Skotiq does not ship it.',
    target: TourTarget.navEquipment,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'profiles',
    title: 'Save it as a profile',
    description:
        'A profile saves your full equipment + framing + filter offset '
        'setup so you can switch between scopes in one click. Profiles '
        'live inside the Equipment screen.',
    target: TourTarget.navEquipment,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'sequencer',
    title: 'Build a sequence',
    description:
        'Build automated imaging sequences here. The Templates tab has '
        'ready-made starting points for narrowband, LRGB, mosaics, and '
        'lunar work — load one and customize.',
    target: TourTarget.navSequencer,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'scheduler',
    title: 'Let the scheduler pick targets',
    description:
        'Plan Tonight ranks what is worth imaging and when, using each '
        "target's altitude through the night and the time you actually "
        'have before dawn.',
    target: TourTarget.navPlanner,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'plate_solving',
    title: 'Set up plate solving',
    description:
        'Plate solving needs ASTAP or Astrometry.net installed. Set it '
        'up under Settings → Plate Solving — Skotiq auto-detects '
        'standard install paths.',
    target: TourTarget.navSettings,
  ),
  TourStep(
    id: 'defect_maps',
    title: 'Defect maps and calibration',
    description: "Open the Imaging screen's Image Calibration section to build "
        'a defect map. Skotiq flags hot, cold, and stuck pixels '
        'from a stack of bias frames so they get masked at capture '
        'time instead of polluting your stack.',
    target: TourTarget.navImaging,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'completion',
    title: "You're set",
    description:
        'Run the tour again any time from Settings → Help & Tutorials.',
  ),
];

// Equipment setup tour (4 steps)
// Profiles -> Drivers -> Connect
const List<TourStep> _equipmentSetup = [
  TourStep(
    id: 'eq_profiles_overview',
    title: 'Equipment profiles',
    description:
        'The Profiles panel lists your equipment configurations. A profile saves one telescope, camera and accessory combination, so you can switch rigs without re-entering anything.',
    target: TourTarget.equipmentProfileSelector,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'eq_create_profile',
    title: 'Create a profile',
    description:
        'The + button at the top of the Profiles panel opens a new configuration. Enter focal length, aperture and your camera details — those are what the field-of-view and pixel-scale figures are computed from.',
    target: TourTarget.equipmentCreateProfileButton,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'eq_connect_devices',
    title: 'Connect devices',
    description:
        'Connect All brings up every device in the selected profile. Use ASCOM COM only on Windows, Alpaca for ASCOM network devices, INDI through a reachable server, and Native only where the release includes the needed SDK.',
    target: TourTarget.equipmentQuickConnectBar,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'eq_verify_status',
    title: 'Verify connections',
    description:
        'Each connected device gets a card here. Green means connected and ready; a device that failed to connect reports the error on the card instead.',
    target: TourTarget.equipmentCameraCard,
    side: TourCardSide.left,
  ),
];

// Target planning tour (4 steps)
// Planetarium -> Search -> Slew -> Frame
const List<TourStep> _targetPlanning = [
  TourStep(
    id: 'tp_planetarium',
    title: 'Open the Planetarium',
    description:
        'Click the Planetarium tab to access the interactive sky chart. This shows your current sky with all visible objects based on your location and time.',
    target: TourTarget.planTabPlanetarium,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'tp_search',
    title: 'Search for objects',
    description:
        'Click the search bar and type an object name (like M31, NGC 7000, or Vega). Select from the results to center the planetarium on that object.',
    target: TourTarget.planetariumSearch,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'tp_slew',
    title: 'Slew to target',
    description:
        'Right-click the object and select "Slew Here" to point your mount at the target. Ensure your mount is connected before slewing.',
    target: TourTarget.planetariumSlewButton,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'tp_framing',
    title: 'Frame your shot',
    description:
        'Navigate to the Framing tab to compose your image. Drag and rotate the field-of-view rectangle to find the perfect composition before imaging.',
    target: TourTarget.planTabFraming,
    side: TourCardSide.right,
  ),
];

// Automated imaging tour (5 steps)
// Sequencer basics -> Build -> Run
const List<TourStep> _automatedImaging = [
  TourStep(
    id: 'ai_sequencer_intro',
    title: 'Meet the Sequencer',
    description:
        'Click the Sequencer tab to access automated imaging. The Sequencer runs your imaging plan unattended, handling slews, exposures, autofocus, and more.',
    target: TourTarget.navSequencer,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'ai_add_blocks',
    title: 'Add sequence blocks',
    description:
        'Add nodes from the palette on the left to the sequence. Start with a Target node, then add Take exposures nodes for your frames. Each node configures one part of your workflow.',
    target: TourTarget.sequencerNodePalette,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'ai_configure',
    title: 'Configure capture settings',
    description:
        'Select a Take exposures node to configure it here. Set the filter, exposure time, gain, and number of frames. Add more of them for different filters (LRGB, narrowband).',
    target: TourTarget.sequencerPropertiesPanel,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'ai_run',
    title: 'Run the sequence',
    description:
        'Start runs your sequence once preflight passes; while a check is failing the button names what to fix instead. Skotiq then runs each node in order, handling equipment control and image saving.',
    target: TourTarget.sequencerTransport,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'ai_monitor',
    title: 'Monitor progress',
    description:
        'Watch the progress panel as your sequence runs. Green checkmarks indicate completed blocks. Click Pause to interrupt, or Stop to end the session. Images save automatically.',
    target: TourTarget.sequencerProgressBar,
    side: TourCardSide.left,
  ),
];

// Calibration frames tour (3 steps)
// Flat wizard workflow
const List<TourStep> _calibrationFrames = [
  TourStep(
    id: 'cf_what_are_flats',
    title: 'What are flat frames?',
    description:
        'Flat frames correct for vignetting and dust spots in your optical system. Navigate to the Flat Wizard tab to capture them easily.',
    target: TourTarget.navFlatWizard,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'cf_wizard_setup',
    title: 'Configure the wizard',
    description:
        'Select your flat source (sky flats, light panel, or EL panel). Set the target ADU level (typically 50% of your camera\'s well depth). The wizard will calculate exposure times automatically.',
    target: TourTarget.flatTargetAdu,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'cf_capture_flats',
    title: 'Capture flat frames',
    description:
        'Click Start to begin capturing. The wizard takes test exposures, adjusts timing, then captures your specified number of flats per filter. Watch the ADU histogram to verify exposure.',
    target: TourTarget.flatStartButton,
    side: TourCardSide.top,
  ),
];

// Advanced features tour (4 steps)
// Analytics, weather, history, settings
const List<TourStep> _advancedFeatures = [
  TourStep(
    id: 'af_analytics',
    title: 'Session Analytics',
    description:
        'Click the Analytics tab to review your imaging performance. View HFR trends, guiding accuracy, and sky conditions over time to identify areas for improvement.',
    target: TourTarget.navAnalytics,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'af_weather',
    title: 'Weather integration',
    description:
        'The Weather screen shows current conditions at a glance. Configure alerts in Settings to pause imaging when clouds approach or humidity rises.',
    target: TourTarget.weatherStatusCard,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'af_history',
    title: 'Session history',
    description:
        'Click the History tab in Analytics to browse past sessions. Review captured frames, total integration time, and conditions for each imaging night.',
    target: TourTarget.analyticsHistoryTab,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'af_settings',
    title: 'Customize settings',
    description:
        'Click the Settings icon in the title bar to configure your location, file paths, plate solving, and other preferences. Set your coordinates for accurate sky calculations.',
    target: TourTarget.navSettings,
    side: TourCardSide.bottom,
  ),
];
