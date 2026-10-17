// Planetarium through polar-alignment screen-tour definitions.
part of '../tutorial_models.dart';

// Planetarium tour (10 steps)
const List<TutorialStep> _planetariumTour = [
  TutorialStep(
    id: 'pt_welcome',
    title: 'Interactive Sky Chart',
    description:
        'The Planetarium shows the sky as seen from your location. Find targets, plan observations, and slew your mount directly to objects of interest.',
    position: TooltipPosition.center,
    order: 0,
    category: TutorialCategory.planetariumTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'pt_sky_view',
    title: 'Sky View',
    description:
        'Drag to pan across the sky, pinch to zoom. Stars are colored by spectral type. Deep sky objects show their catalog designations and approximate sizes.',
    targetKey: 'planetarium_sky_view',
    position: TooltipPosition.center,
    order: 1,
    category: TutorialCategory.planetariumTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'pt_search',
    title: 'Search Bar',
    description:
        'Search for any object by name, catalog number, or coordinates. Type "M31", "NGC 7000", or "Vega" and select from matching results.',
    targetKey: 'planetarium_search',
    position: TooltipPosition.bottom,
    order: 2,
    category: TutorialCategory.planetariumTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'pt_filter_btn',
    title: 'Filter Controls',
    description:
        'Show or hide different object types. Filter by catalog (Messier, NGC, IC), object type (galaxies, nebulae, clusters), or magnitude limit.',
    targetKey: 'planetarium_filter_btn',
    position: TooltipPosition.bottom,
    order: 3,
    category: TutorialCategory.planetariumTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'pt_fov_toggle',
    title: 'FOV Overlay',
    description:
        'Toggle your camera\'s field of view overlay. The rectangle shows exactly what your sensor will capture. Essential for framing planning.',
    targetKey: 'planetarium_fov_toggle',
    position: TooltipPosition.bottom,
    order: 4,
    category: TutorialCategory.planetariumTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'pt_slew_btn',
    title: 'Slew Mode',
    description:
        'Enable slew mode, then tap any location to command your mount. The mount will slew to the selected coordinates. Requires a connected mount.',
    targetKey: 'planetarium_slew_btn',
    position: TooltipPosition.bottom,
    order: 5,
    category: TutorialCategory.planetariumTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'pt_object_popup',
    title: 'Object Information',
    description:
        'Tap any object to see details: name, coordinates, magnitude, size, and rise/set times. Links connect to online databases for more information.',
    targetKey: 'planetarium_object_popup',
    position: TooltipPosition.center,
    order: 6,
    category: TutorialCategory.planetariumTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'pt_send_framing',
    title: 'Send to Framing',
    description:
        'Send the selected object to the Framing screen to compose your shot. Adjust rotation and exact positioning before starting your sequence.',
    targetKey: 'planetarium_send_framing',
    position: TooltipPosition.top,
    order: 7,
    category: TutorialCategory.planetariumTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'pt_add_sequence',
    title: 'Add to Sequencer',
    description:
        'Add the object directly to your sequence as a new target. Skotiq creates a target node with proper coordinates ready for capture.',
    targetKey: 'planetarium_add_sequence',
    position: TooltipPosition.top,
    order: 8,
    category: TutorialCategory.planetariumTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'pt_complete',
    title: 'Sky Explorer',
    description:
        'You know the Planetarium! Use it to discover targets, check visibility windows, and plan your imaging sessions around the best observing conditions.',
    position: TooltipPosition.center,
    order: 9,
    category: TutorialCategory.planetariumTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// Framing tour (10 steps)
const List<TutorialStep> _framingTour = [
  TutorialStep(
    id: 'ft_welcome',
    title: 'Framing Assistant',
    description:
        'The Framing screen helps you compose the perfect shot. Position your target, rotate the field, and plan mosaics before you start imaging.',
    position: TooltipPosition.center,
    order: 0,
    category: TutorialCategory.framingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'ft_target_search',
    title: 'Target Search',
    description:
        'Search for your target by name or enter coordinates directly. The view centers on your selection with a survey image background.',
    targetKey: 'framing_target_search',
    position: TooltipPosition.bottom,
    order: 1,
    category: TutorialCategory.framingTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'ft_canvas',
    title: 'Framing Canvas',
    description:
        'The canvas shows a survey image of your target area. Drag to reposition, pinch to zoom. Your camera\'s field of view is overlaid on top.',
    targetKey: 'framing_canvas',
    position: TooltipPosition.center,
    order: 2,
    category: TutorialCategory.framingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'ft_fov_rect',
    title: 'FOV Rectangle',
    description:
        'This rectangle represents your sensor\'s field of view. Drag to position, use the corner handles to rotate. The coordinates update as you adjust.',
    targetKey: 'framing_fov_rect',
    position: TooltipPosition.center,
    order: 3,
    category: TutorialCategory.framingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'ft_rotation',
    title: 'Rotation Control',
    description:
        'Set the exact camera rotation angle here. Match your rotator position or find the optimal angle for your composition.',
    targetKey: 'framing_rotation',
    position: TooltipPosition.left,
    order: 4,
    category: TutorialCategory.framingTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'ft_coordinates',
    title: 'Coordinates',
    description:
        'View and fine-tune the exact RA/Dec coordinates. These are the coordinates that will be sent to your mount when you slew.',
    targetKey: 'framing_coordinates',
    position: TooltipPosition.left,
    order: 5,
    category: TutorialCategory.framingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'ft_altitude_chart',
    title: 'Altitude Chart',
    description:
        'See when your target is highest in the sky. The chart shows altitude over the night with the optimal imaging window highlighted.',
    targetKey: 'framing_altitude_chart',
    position: TooltipPosition.top,
    order: 6,
    category: TutorialCategory.framingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'ft_mosaic_btn',
    title: 'Mosaic Planning',
    description:
        'Create multi-panel mosaics for large targets. Set overlap percentage, panel count, and Skotiq calculates all the pointing positions.',
    targetKey: 'framing_mosaic_btn',
    position: TooltipPosition.left,
    order: 7,
    category: TutorialCategory.framingTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'ft_slew_btn',
    title: 'Slew to Frame',
    description:
        'Send the framed coordinates to your mount. The mount slews to position and can plate solve to verify pointing accuracy.',
    targetKey: 'framing_slew_btn',
    position: TooltipPosition.left,
    order: 8,
    category: TutorialCategory.framingTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'ft_complete',
    title: 'Perfect Framing',
    description:
        'You\'ve learned framing! Take time to compose your shots before imaging. Good framing makes the difference between a snapshot and a stunning image.',
    position: TooltipPosition.center,
    order: 9,
    category: TutorialCategory.framingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// Analytics tour (8 steps)
const List<TutorialStep> _analyticsTour = [
  TutorialStep(
    id: 'at_welcome',
    title: 'Session Analytics',
    description:
        'The Analytics screen tracks your imaging performance over time. Review sessions, identify trends, and improve your technique with data-driven insights.',
    position: TooltipPosition.center,
    order: 0,
    category: TutorialCategory.analyticsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'at_session_tab',
    title: 'Current Session',
    description:
        'View statistics for your active imaging session. Track frames captured, total integration time, and quality metrics in real-time.',
    targetKey: 'analytics_session_tab',
    position: TooltipPosition.bottom,
    order: 1,
    category: TutorialCategory.analyticsTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'at_history_tab',
    title: 'Session History',
    description:
        'Browse past imaging sessions. Each session shows the date, target, total frames, and conditions. Click any session for detailed analysis.',
    targetKey: 'analytics_history_tab',
    position: TooltipPosition.bottom,
    order: 2,
    category: TutorialCategory.analyticsTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'at_equipment_tab',
    title: 'Equipment Stats',
    description:
        'Track performance by equipment. See which camera/telescope combinations produce the best results and identify gear that needs attention.',
    targetKey: 'analytics_equipment_tab',
    position: TooltipPosition.bottom,
    order: 3,
    category: TutorialCategory.analyticsTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'at_hfr_chart',
    title: 'HFR Chart',
    description:
        'The HFR (Half Flux Radius) chart shows focus quality over time. Sudden increases indicate focus drift. Temperature correlation helps predict when to refocus.',
    targetKey: 'analytics_hfr_chart',
    position: TooltipPosition.left,
    order: 4,
    category: TutorialCategory.analyticsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'at_guiding_chart',
    title: 'Guiding Chart',
    description:
        'Review guiding performance throughout your session. Identify periods of poor seeing or mount issues. Correlate with image quality for best frames.',
    targetKey: 'analytics_guiding_chart',
    position: TooltipPosition.left,
    order: 5,
    category: TutorialCategory.analyticsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'at_thumbnails',
    title: 'Captured Images',
    description:
        'Browse thumbnails of all captured frames. Click any image for full-size view with metadata. Flag best frames or mark rejects for stacking.',
    targetKey: 'analytics_thumbnails',
    position: TooltipPosition.top,
    order: 6,
    category: TutorialCategory.analyticsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'at_complete',
    title: 'Data Insights',
    description:
        'Use Analytics to continuously improve! Track trends across sessions, identify optimal conditions, and refine your imaging technique over time.',
    position: TooltipPosition.center,
    order: 7,
    category: TutorialCategory.analyticsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// Flat wizard tour (8 steps)
const List<TutorialStep> _flatWizardTour = [
  TutorialStep(
    id: 'fwt_welcome',
    title: 'Flat Frame Wizard',
    description:
        'The Flat Wizard automates flat frame capture. It calculates optimal exposure times and captures flats for all your filters with minimal effort.',
    position: TooltipPosition.center,
    order: 0,
    category: TutorialCategory.flatWizardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'fwt_tabs',
    title: 'Capture Modes',
    description:
        'Choose between Sky Flats (twilight), Panel Flats (light panel), or Manual mode. Each mode optimizes the workflow for your flat source.',
    targetKey: 'flat_tabs',
    position: TooltipPosition.bottom,
    order: 1,
    category: TutorialCategory.flatWizardTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'fwt_filter_select',
    title: 'Filter Selection',
    description:
        'Select which filters to capture flats for. The wizard captures flats in optimal order for sky flats (brightest to dimmest at dusk).',
    targetKey: 'flat_filter_select',
    position: TooltipPosition.left,
    order: 2,
    category: TutorialCategory.flatWizardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'fwt_target_adu',
    title: 'Target ADU',
    description:
        'Set the target brightness level for your flats. Typically 30-50% of your camera\'s full well capacity. The wizard adjusts exposure to hit this target.',
    targetKey: 'flat_target_adu',
    position: TooltipPosition.left,
    order: 3,
    category: TutorialCategory.flatWizardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'fwt_frame_count',
    title: 'Frame Count',
    description:
        'Specify how many flats to capture per filter. 20-30 flats per filter provides good signal for master flat creation.',
    targetKey: 'flat_frame_count',
    position: TooltipPosition.left,
    order: 4,
    category: TutorialCategory.flatWizardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'fwt_preview',
    title: 'Preview Panel',
    description:
        'Watch the live preview as flats are captured. The histogram shows ADU distribution. Adjust exposure if the histogram isn\'t centered on your target.',
    targetKey: 'flat_preview',
    position: TooltipPosition.left,
    order: 5,
    category: TutorialCategory.flatWizardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'fwt_start_btn',
    title: 'Start Capture',
    description:
        'Click Start to begin the flat capture sequence. The wizard handles exposure calculation, filter changes, and file naming automatically.',
    targetKey: 'flat_start_btn',
    position: TooltipPosition.top,
    order: 6,
    category: TutorialCategory.flatWizardTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'fwt_complete',
    title: 'Flats Made Easy',
    description:
        'Flat frames are essential for clean images. Use the wizard at dusk or dawn for sky flats, or anytime with a flat panel. Consistent flats = better stacks!',
    position: TooltipPosition.center,
    order: 7,
    category: TutorialCategory.flatWizardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// Weather tour (8 steps)
const List<TutorialStep> _weatherTour = [
  TutorialStep(
    id: 'wt_welcome',
    title: 'Weather Monitoring',
    description:
        'The Weather screen provides detailed forecasting and real-time conditions. Plan sessions around clear skies and protect your equipment from incoming weather.',
    position: TooltipPosition.center,
    order: 0,
    category: TutorialCategory.weatherTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'wt_radar_map',
    title: 'Radar Map',
    description:
        'Live radar shows precipitation and cloud cover in your area. The animation shows movement direction. Plan around approaching systems.',
    targetKey: 'weather_radar_map',
    position: TooltipPosition.left,
    order: 1,
    category: TutorialCategory.weatherTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'wt_timeline',
    title: 'Timeline',
    description:
        'Scrub through the forecast timeline to see predicted conditions hour by hour. Find the optimal imaging window for tonight.',
    targetKey: 'weather_timeline',
    position: TooltipPosition.top,
    order: 2,
    category: TutorialCategory.weatherTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'wt_status_card',
    title: 'Conditions',
    description:
        'Current conditions at a glance: temperature, humidity, dew point, wind, and cloud cover. The imaging safety indicator shows if conditions are favorable.',
    targetKey: 'weather_status_card',
    position: TooltipPosition.left,
    order: 3,
    category: TutorialCategory.weatherTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'wt_alert_radius',
    title: 'Alert Radius',
    description:
        'Set the distance at which approaching weather triggers alerts. Smaller radius for permanent setups, larger for time to pack up portable gear.',
    targetKey: 'weather_alert_radius',
    position: TooltipPosition.left,
    order: 4,
    category: TutorialCategory.weatherTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'wt_cloud_motion',
    title: 'Cloud Motion',
    description:
        'AI-powered cloud motion analysis predicts when clouds will reach your location. Get advance warning before conditions deteriorate.',
    targetKey: 'weather_cloud_motion',
    position: TooltipPosition.left,
    order: 5,
    category: TutorialCategory.weatherTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'wt_refresh_btn',
    title: 'Refresh',
    description:
        'Manually refresh weather data. Automatic updates occur every 15 minutes, but you can force an update when conditions are changing rapidly.',
    targetKey: 'weather_refresh_btn',
    position: TooltipPosition.left,
    order: 6,
    category: TutorialCategory.weatherTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'wt_complete',
    title: 'Weather Aware',
    description:
        'Stay ahead of the weather! Configure alerts in Settings to automatically pause sequences when conditions threaten. Protect your gear and optimize imaging time.',
    position: TooltipPosition.center,
    order: 7,
    category: TutorialCategory.weatherTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// Settings tour (10 steps)
const List<TutorialStep> _settingsTour = [
  TutorialStep(
    id: 'stt_welcome',
    title: 'Application Settings',
    description:
        'Configure Skotiq to match your setup and preferences. Location, file paths, plate solving, and appearance options are all here.',
    position: TooltipPosition.center,
    order: 0,
    category: TutorialCategory.settingsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'stt_categories',
    title: 'Categories',
    description:
        'Settings are organized into categories. Click any category to view and modify its options. Changes save automatically.',
    targetKey: 'settings_categories',
    position: TooltipPosition.right,
    order: 1,
    category: TutorialCategory.settingsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'stt_connection',
    title: 'Connection',
    description:
        'Configure how Skotiq connects to equipment. Set ASCOM/INDI/Alpaca preferences, network timeouts, and auto-reconnect behavior.',
    targetKey: 'settings_connection',
    position: TooltipPosition.right,
    order: 2,
    category: TutorialCategory.settingsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'stt_location',
    title: 'Location',
    description:
        'Set your observatory coordinates. Accurate location is essential for planetarium calculations, altitude predictions, and meridian flip timing.',
    targetKey: 'settings_location',
    position: TooltipPosition.right,
    order: 3,
    category: TutorialCategory.settingsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'stt_appearance',
    title: 'Appearance',
    description:
        'Customize the look and feel. Choose dark or light themes, accent colors, and font sizes. Night mode preserves your dark adaptation.',
    targetKey: 'settings_appearance',
    position: TooltipPosition.right,
    order: 4,
    category: TutorialCategory.settingsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'stt_file_paths',
    title: 'File Paths',
    description:
        'Configure where images are saved. Set up folder structures with date, target, and filter substitutions. Keep your image library organized.',
    targetKey: 'settings_file_paths',
    position: TooltipPosition.right,
    order: 5,
    category: TutorialCategory.settingsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'stt_plate_solving',
    title: 'Plate Solving',
    description:
        'Configure your plate solver. Set paths to solver binaries, index files, and search parameters. Local solving is faster than online services.',
    targetKey: 'settings_plate_solving',
    position: TooltipPosition.right,
    order: 6,
    category: TutorialCategory.settingsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'stt_notifications',
    title: 'Notifications',
    description:
        'Control when and how Skotiq alerts you. Set up email, SMS, or push notifications for sequence completion, errors, or weather alerts.',
    targetKey: 'settings_notifications',
    position: TooltipPosition.right,
    order: 7,
    category: TutorialCategory.settingsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'stt_help',
    title: 'Help & Tutorials',
    description:
        'Access all tutorials from here. Reset tutorial progress, view documentation, or contact support. Tutorials can be replayed anytime.',
    targetKey: 'settings_help',
    position: TooltipPosition.right,
    order: 8,
    category: TutorialCategory.settingsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'stt_complete',
    title: 'Personalized',
    description:
        'Skotiq is now configured to your preferences! Revisit Settings anytime to fine-tune your experience as you discover what works best.',
    position: TooltipPosition.center,
    order: 9,
    category: TutorialCategory.settingsTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// Polar alignment tour (10 steps)
const List<TutorialStep> _polarAlignmentTour = [
  TutorialStep(
    id: 'pat_welcome',
    title: 'Polar Alignment',
    description:
        'The Polar Alignment wizard helps you achieve accurate polar alignment using plate solving. No need for a polar scope - just follow the guided process.',
    position: TooltipPosition.center,
    order: 0,
    category: TutorialCategory.polarAlignmentTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'pat_hemisphere',
    title: 'Hemisphere',
    description:
        'Select your hemisphere. This determines whether to use Polaris (north) or Sigma Octantis (south) as the reference point.',
    targetKey: 'polar_hemisphere',
    position: TooltipPosition.right,
    order: 1,
    category: TutorialCategory.polarAlignmentTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'pat_exposure',
    title: 'Exposure Time',
    description:
        'Set the exposure time for measurement images. Longer exposures improve accuracy but take more time. 2-5 seconds usually works well.',
    targetKey: 'polar_exposure',
    position: TooltipPosition.right,
    order: 2,
    category: TutorialCategory.polarAlignmentTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'pat_step_size',
    title: 'Step Size',
    description:
        'The mount rotation between measurements. Larger steps are faster but less precise. 30 degrees is a good starting point.',
    targetKey: 'polar_step_size',
    position: TooltipPosition.right,
    order: 3,
    category: TutorialCategory.polarAlignmentTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'pat_start_btn',
    title: 'Start',
    description:
        'Begin the alignment process. Skotiq will take images, rotate the mount, and calculate your polar alignment error.',
    targetKey: 'polar_start_btn',
    position: TooltipPosition.right,
    order: 4,
    category: TutorialCategory.polarAlignmentTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'pat_image_view',
    title: 'Measurement',
    description:
        'Watch as Skotiq captures and plate solves images. Each solve refines the polar alignment calculation. The process typically takes 2-3 images.',
    targetKey: 'polar_image_view',
    position: TooltipPosition.left,
    order: 5,
    category: TutorialCategory.polarAlignmentTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'pat_error_display',
    title: 'Error Display',
    description:
        'Your polar alignment error in arcminutes. For visual observing, under 10\' is fine. For imaging, aim for under 2\' for excellent tracking.',
    targetKey: 'polar_error_display',
    position: TooltipPosition.left,
    order: 6,
    category: TutorialCategory.polarAlignmentTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'pat_adjustment',
    title: 'Adjustment Guide',
    description:
        'Follow the arrows to adjust your mount\'s altitude and azimuth knobs. The display updates in real-time as you make adjustments.',
    targetKey: 'polar_adjustment',
    position: TooltipPosition.left,
    order: 7,
    category: TutorialCategory.polarAlignmentTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'pat_progress',
    title: 'Progress Steps',
    description:
        'Track your progress through the alignment process. Each step shows completion status. Re-measure after adjustments to verify improvement.',
    targetKey: 'polar_progress',
    position: TooltipPosition.top,
    order: 8,
    category: TutorialCategory.polarAlignmentTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'pat_complete',
    title: 'Alignment Complete',
    description:
        'Great polar alignment means better tracking and easier guiding. Re-run the wizard periodically if your setup isn\'t permanent.',
    position: TooltipPosition.center,
    order: 9,
    category: TutorialCategory.polarAlignmentTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];
