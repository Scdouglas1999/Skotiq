part of '../tour.dart';

// Tonight tour (6 steps). Every step is centered: the tour names the
// screen's regions rather than spotlighting widgets.
const List<TourStep> _dashboardTour = [
  TourStep(
    id: 'dt_welcome',
    title: 'Welcome to Tonight',
    description:
        'Tonight is where you run the night: the plan on the left, the latest frame in the middle and the equipment panel on the right.',
  ),
  TourStep(
    id: 'dt_header',
    title: 'Run Controls',
    description:
        'The header shows the run\'s state, the night from sunset to sunrise and the run controls: Start now or Start at dark before a run, then Pause, Skip step and a hold-to-confirm Stop.',
  ),
  TourStep(
    id: 'dt_plan',
    title: 'The Plan',
    description:
        'The left column lists the target, the plan\'s progress by filter and every step with its time. Open a step in the Sequencer to change it.',
  ),
  TourStep(
    id: 'dt_frame',
    title: 'Frame and Manual Actions',
    description:
        'The center shows the latest frame with its HFR and star count, the frames taken this session and the focus, guiding and temperature charts. The buttons under the frame run a snapshot, autofocus, a solve or a dither; during a run they pause it after the current frame and resume it afterwards.',
  ),
  TourStep(
    id: 'dt_panel',
    title: 'Equipment Panel',
    description:
        'The tabs on the right hold the camera, focuser, mount, guider and plate solver. A dot on a tab means something there needs a look; the panel never switches tabs on its own.',
  ),
  TourStep(
    id: 'dt_complete',
    title: 'Tour Complete',
    description:
        'That is Tonight. Load a plan in the Sequencer, then come back here to start it.',
  ),
];

// Equipment tour (10 steps)
const List<TourStep> _equipmentTour = [
  TourStep(
    id: 'et_welcome',
    title: 'Equipment Management',
    description:
        'The Equipment screen is where you configure and connect all your astrophotography gear. Create profiles to quickly switch between different setups.',
  ),
  TourStep(
    id: 'et_profile_selector',
    title: 'Equipment Profiles',
    description:
        'Select from saved equipment profiles. Each profile stores your telescope, camera, and accessory configurations. Switch profiles when changing imaging rigs.',
    target: TourTarget.equipmentProfileSelector,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'et_create_profile',
    title: 'Create Profile',
    description:
        'Click to create a new equipment profile. Enter your sensor dimensions, pixel size, and focal length to enable accurate field-of-view calculations throughout Skotiq.',
    target: TourTarget.equipmentCreateProfileButton,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'et_quick_connect',
    title: 'Connect All',
    description:
        'Connect all brings up every device in the selected profile that is not connected yet. It is offered only while something in the profile is disconnected.',
    target: TourTarget.equipmentQuickConnectBar,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'et_discovery_tab',
    title: 'Device Discovery',
    description:
        'Scan for devices looks for Windows ASCOM COM drivers, configured or reachable INDI servers, and Alpaca devices on your network when those backends are in scope for the release. What it finds is listed at the bottom of the Devices tab.',
    target: TourTarget.equipmentScanButton,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'et_connected_tab',
    title: 'Devices',
    description:
        'The Devices tab shows a card for each device of the active profile, with its status and its controls.',
    target: TourTarget.equipmentDevicesTab,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'et_settings_tab',
    title: 'Profile Actions',
    description:
        'The menu beside the profile name edits the profile, disconnects everything, lists all profiles and opens Equipment settings.',
    target: TourTarget.equipmentProfileMenu,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'et_camera_card',
    title: 'Camera Controls',
    description:
        'The camera card shows the sensor temperature, cooler power and state. Cool the sensor to its target temperature or warm it up from here; the menu on the card has the rest.',
    target: TourTarget.equipmentCameraCard,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'et_mount_card',
    title: 'Mount Controls',
    description:
        'The mount card shows where the mount is pointing and its state, with Park or Unpark and Home. The menu on the card has the rest.',
    target: TourTarget.equipmentMountCard,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'et_complete',
    title: 'Equipment Ready',
    description:
        'You\'re now familiar with equipment management! Create profiles for each of your setups and use Quick Connect for fast session startup.',
  ),
];

// Imaging tour (15 steps)
const List<TourStep> _imagingTour = [
  TourStep(
    id: 'it_welcome',
    title: 'The Imaging Screen',
    description:
        'The Imaging screen is your primary interface for capturing images. Control your camera, view live images, and monitor image quality all in one place.',
  ),
  TourStep(
    id: 'it_tab_bar',
    title: 'View Tabs',
    description:
        'Switch between Live view, Live stack and Session frames. Live view shows each frame as it arrives, Live stack builds a running stack, and Session frames lists what this session has captured.',
    target: TourTarget.imagingTabBar,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'it_preview_area',
    title: 'Image Preview',
    description:
        'Your captured images appear here with auto-stretch applied. Pinch to zoom, drag to pan, and double-tap to reset the view. The crosshair marks the image center.',
    target: TourTarget.imagingPreviewArea,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'it_zoom_controls',
    title: 'Zoom Controls',
    description:
        'Zoom in to inspect star shapes and check focus. The 1:1 button shows actual pixels. Use zoom during focusing to see the tightest star shapes.',
    target: TourTarget.imagingZoomControls,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'it_exposure_slider',
    title: 'Exposure Time',
    description:
        'Set your exposure duration here. For focusing, use short exposures (1-3 seconds). For imaging, typical exposures range from 60-300 seconds depending on your target.',
    target: TourTarget.imagingExposureSlider,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'it_gain_control',
    title: 'Gain Setting',
    description:
        'Adjust camera gain (sensitivity). Higher gain means brighter images but more noise. Find your camera\'s unity gain or optimal gain for best results.',
    target: TourTarget.imagingGainControl,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'it_filter_selector',
    title: 'Filter Selection',
    description:
        'Choose the active filter from your filter wheel. Skotiq remembers focus offsets for each filter and applies them automatically.',
    target: TourTarget.imagingFilterSelector,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'it_snapshot_btn',
    title: 'Snapshot Button',
    description:
        'Take a single exposure with current settings. The image appears in the preview when complete. Use snapshots for framing and focus checks.',
    target: TourTarget.imagingSnapshotButton,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'it_loop_btn',
    title: 'Loop Capture',
    description:
        'Start continuous exposures that repeat until stopped. Essential for focusing — watch the stars tighten as you adjust. HFR updates with each frame.',
    target: TourTarget.imagingLoopButton,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'it_abort_btn',
    title: 'Abort Button',
    description:
        'Stop the current exposure immediately. The partial image is discarded. Use this when you need to make quick adjustments.',
    target: TourTarget.imagingAbortButton,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'it_stats_panel',
    title: 'Image Statistics',
    description:
        'View key metrics: HFR (star size), median ADU, detected stars, and more. Lower HFR means better focus. Watch these numbers during your session.',
    target: TourTarget.imagingStatsPanel,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'it_mount_tab',
    title: 'Mount Controls',
    description:
        'Open the Mount section of the side panel for mount controls without leaving the Imaging screen. Slew to coordinates, sync position, or make fine adjustments while viewing your image.',
    target: TourTarget.imagingMountTab,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'it_focus_tab',
    title: 'Focus Controls',
    description:
        'Open the Focus section of the side panel to run autofocus or move the focuser by hand. The focus graph shows your V-curve.',
    target: TourTarget.imagingFocusTab,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'it_histogram',
    title: 'Histogram',
    description:
        'The histogram shows the brightness distribution of your image. A well-exposed light frame should have the peak slightly left of center.',
    target: TourTarget.imagingHistogram,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'it_complete',
    title: 'Imaging Mastered',
    description:
        'You know the Imaging screen! Use Loop mode for focusing, check HFR for quality, and keep an eye on your histogram for proper exposure.',
  ),
];

// Guiding tour (10 steps)
const List<TourStep> _guidingTour = [
  TourStep(
    id: 'gt_welcome',
    title: 'Guiding',
    description:
        'The Guiding screen runs autoguiding with the built-in guider or PHD2. Monitor guide star tracking, view correction graphs, and control guiding directly from Skotiq.',
  ),
  TourStep(
    id: 'gt_connect_btn',
    title: 'Connect the Guider',
    description:
        'Connect or disconnect the guider here. With PHD2, make sure PHD2 is running and its server is enabled. Once connected, Skotiq can start and stop guiding and receive performance data.',
    target: TourTarget.guidingConnectButton,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'gt_status_bar',
    title: 'Connection Status',
    description:
        "Shows the guider's connection state and guiding status. Green means actively guiding, yellow means calibrating, red indicates an issue.",
    target: TourTarget.guidingStatusBar,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'gt_star_view',
    title: 'Guide Star View',
    description:
        'See your guide star in real-time. The crosshair shows the lock position. A stable, non-saturated star makes the best guide star.',
    target: TourTarget.guidingStarView,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'gt_target_display',
    title: 'Target Display',
    description:
        'The target shows guide corrections as dots. Tight clustering near center indicates excellent guiding. Spread-out dots suggest issues to investigate.',
    target: TourTarget.guidingTargetDisplay,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'gt_graph',
    title: 'Guiding Graph',
    description:
        'The graph shows RA (blue) and Dec (red) corrections over time. Flat lines near zero mean perfect tracking. Regular patterns may indicate periodic error.',
    target: TourTarget.guidingGraph,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'gt_rms_display',
    title: 'RMS Statistics',
    description:
        'RMS values quantify guiding accuracy in arcseconds. Lower is better. Under 1" total RMS is excellent for most setups. Watch for trends over time.',
    target: TourTarget.guidingRmsDisplay,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'gt_controls',
    title: 'Guiding Controls',
    description:
        'Start, stop, and pause guiding. Dither between exposures for better stacking. These controls sync with your active sequence automatically.',
    target: TourTarget.guidingControls,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'gt_brain_btn',
    title: 'Guider Settings',
    description:
        "Open the guider's advanced settings: guide algorithms, calibration and more. Most users won't need to change these.",
    target: TourTarget.guidingBrainButton,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'gt_complete',
    title: 'Guiding Ready',
    description:
        'You understand the Guiding screen! For best results, select a bright but unsaturated guide star and aim for sub-arcsecond RMS values.',
  ),
];

// Sequencer tour (12 steps)
const List<TourStep> _sequencerTour = [
  TourStep(
    id: 'st_welcome',
    title: 'The Sequencer',
    description:
        'The Sequencer automates your entire imaging session. Build sequences with drag-and-drop, save templates, and let Skotiq image all night unattended.',
  ),
  TourStep(
    id: 'st_tab_builder',
    title: 'Builder Tab',
    description:
        'Create and edit sequences in the Builder. Add nodes from the palette to the sequence and configure each step of your workflow.',
    target: TourTarget.sequencerTabBuilder,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'st_tab_templates',
    title: 'Templates Tab',
    description:
        'Browse built-in Starters and your saved templates. Tap a Starter to load a complete, ready-to-run sequence, or save your own workflows like LRGB imaging, narrowband, or quick snapshots for reuse.',
    target: TourTarget.sequencerTabTemplates,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'st_node_palette',
    title: 'Node Palette',
    description:
        'Drag nodes from here onto the canvas. Choose from Target nodes, Capture nodes, Autofocus, Filter changes, Dither, and more.',
    target: TourTarget.sequencerNodePalette,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'st_canvas',
    title: 'Sequence Canvas',
    description:
        'Your sequence, top to bottom. Drop nodes here from the palette, or double-click one in the palette to add it. A node runs the nodes inside it, and the sequence runs from the top.',
    target: TourTarget.sequencerCanvas,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'st_target_node',
    title: 'Target Nodes',
    description:
        'Target nodes slew to objects and center using plate solving. Add coordinates manually or import from the Planetarium or Framing screens.',
    target: TourTarget.sequencerTargetNode,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'st_capture_node',
    title: 'Capture Nodes',
    description:
        'Capture nodes take your images. Configure filter, exposure, gain, and frame count. Add multiple Capture nodes for multi-filter imaging.',
    target: TourTarget.sequencerCaptureNode,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'st_properties_panel',
    title: 'Properties Panel',
    description:
        'Select any node to view and edit its properties here. Set exposure times, filter selections, loop counts, and advanced options.',
    target: TourTarget.sequencerPropertiesPanel,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'st_toolbar',
    title: 'Sequence Toolbar',
    description:
        'The toolbar names the sequence and counts its errors and warnings, and holds undo, redo, the view options and Save. Save your sequences frequently!',
    target: TourTarget.sequencerToolbar,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'st_progress_bar',
    title: 'Progress Indicator',
    description:
        'Track sequence progress here. See completed, current, and remaining steps. Estimated completion time updates based on actual performance.',
    target: TourTarget.sequencerProgressBar,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'st_complete',
    title: 'Sequencer Expert',
    description:
        'You\'ve mastered the Sequencer! Build sequences for unattended imaging, save templates for quick setup, and let Skotiq do the work.',
  ),
];

// Planetarium tour (10 steps)
const List<TourStep> _planetariumTour = [
  TourStep(
    id: 'pt_welcome',
    title: 'Interactive Sky Chart',
    description:
        'The Planetarium shows the sky as seen from your location. Find targets, plan observations, and slew your mount directly to objects of interest.',
  ),
  TourStep(
    id: 'pt_sky_view',
    title: 'Sky View',
    description:
        'Drag to pan across the sky, pinch to zoom. Stars are colored by spectral type. Deep sky objects show their catalog designations and approximate sizes.',
    target: TourTarget.planetariumSkyView,
  ),
  TourStep(
    id: 'pt_search',
    title: 'Search Bar',
    description:
        'Search for any object by name, catalog number, or coordinates. Type "M31", "NGC 7000", or "Vega" and select from matching results.',
    target: TourTarget.planetariumSearch,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'pt_filter_btn',
    title: 'Layers',
    description:
        'Open Layers to show or hide object types and catalogs (Messier, NGC, IC), constellation lines, grids and labels.',
    target: TourTarget.planetariumLayersButton,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'pt_fov_toggle',
    title: 'FOV Overlay',
    description:
        'Toggle your camera\'s field of view overlay. The rectangle shows exactly what your sensor will capture. Essential for framing planning.',
    target: TourTarget.planetariumFovToggle,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'pt_slew_btn',
    title: 'Slew Mode',
    description:
        'Enable slew mode, then tap any location to command your mount. The mount will slew to the selected coordinates. Requires a connected mount.',
    target: TourTarget.planetariumSlewButton,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'pt_object_popup',
    title: 'Object Information',
    description:
        'Tap any object to see details: name, coordinates, magnitude, size, and rise/set times. Links connect to online databases for more information.',
    target: TourTarget.planetariumObjectPopup,
  ),
  TourStep(
    id: 'pt_send_framing',
    title: 'Send to Framing',
    description:
        'Send the selected object to the Framing screen to compose your shot. Adjust rotation and exact positioning before starting your sequence.',
    target: TourTarget.planetariumSendToFraming,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'pt_add_sequence',
    title: 'Add to Sequencer',
    description:
        'Add the object directly to your sequence as a new target. Skotiq creates a target node with proper coordinates ready for capture.',
    target: TourTarget.planetariumAddToSequence,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'pt_complete',
    title: 'Sky Explorer',
    description:
        'You know the Planetarium! Use it to discover targets, check visibility windows, and plan your imaging sessions around the best observing conditions.',
  ),
];

// Framing tour (10 steps)
const List<TourStep> _framingTour = [
  TourStep(
    id: 'ft_welcome',
    title: 'Framing Assistant',
    description:
        'The Framing screen helps you compose the perfect shot. Position your target, rotate the field, and plan mosaics before you start imaging.',
  ),
  TourStep(
    id: 'ft_target_search',
    title: 'Target Search',
    description:
        'Search for your target by name or enter coordinates directly. The view centers on your selection with a survey image background.',
    target: TourTarget.framingTargetSearch,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'ft_canvas',
    title: 'Framing Canvas',
    description:
        'The canvas shows a survey image of your target area. Drag to reposition, pinch to zoom. Your camera\'s field of view is overlaid on top.',
    target: TourTarget.framingCanvas,
  ),
  TourStep(
    id: 'ft_fov_rect',
    title: 'FOV Rectangle',
    description:
        'This rectangle represents your sensor\'s field of view. Drag to position, use the corner handles to rotate. The coordinates update as you adjust.',
    target: TourTarget.framingFovRect,
  ),
  TourStep(
    id: 'ft_rotation',
    title: 'Rotation Control',
    description:
        'Set the exact camera rotation angle here. Match your rotator position or find the optimal angle for your composition.',
    target: TourTarget.framingRotation,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'ft_coordinates',
    title: 'Coordinates',
    description:
        'View and fine-tune the exact RA/Dec coordinates. These are the coordinates that will be sent to your mount when you slew.',
    target: TourTarget.framingCoordinates,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'ft_altitude_chart',
    title: 'Altitude Chart',
    description:
        'See when your target is highest in the sky. The chart shows altitude over the night with the optimal imaging window highlighted.',
    target: TourTarget.framingAltitudeChart,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'ft_mosaic_btn',
    title: 'Mosaic Planning',
    description:
        'Create multi-panel mosaics for large targets. Set overlap percentage, panel count, and Skotiq calculates all the pointing positions.',
    target: TourTarget.framingMosaicButton,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'ft_slew_btn',
    title: 'Slew to Frame',
    description:
        'Send the framed coordinates to your mount. The mount slews to position and can plate solve to verify pointing accuracy.',
    target: TourTarget.framingSlewButton,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'ft_complete',
    title: 'Perfect Framing',
    description:
        'You\'ve learned framing! Take time to compose your shots before imaging. Good framing makes the difference between a snapshot and a stunning image.',
  ),
];

// Analytics tour (8 steps)
const List<TourStep> _analyticsTour = [
  TourStep(
    id: 'at_welcome',
    title: 'Session Analytics',
    description:
        'The Analytics screen tracks your imaging performance over time. Review sessions, identify trends, and improve your technique with data-driven insights.',
  ),
  TourStep(
    id: 'at_session_tab',
    title: 'Current Session',
    description:
        'View statistics for your active imaging session. Track frames captured, total integration time, and quality metrics in real-time.',
    target: TourTarget.analyticsSessionTab,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'at_history_tab',
    title: 'Session History',
    description:
        'Browse past imaging sessions. Each session shows the date, target, total frames, and conditions. Click any session for detailed analysis.',
    target: TourTarget.analyticsHistoryTab,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'at_equipment_tab',
    title: 'Equipment Stats',
    description:
        'Track performance by equipment. See which camera/telescope combinations produce the best results and identify gear that needs attention.',
    target: TourTarget.analyticsEquipmentTab,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'at_hfr_chart',
    title: 'HFR Chart',
    description:
        'The HFR (Half Flux Radius) chart shows focus quality over time. Sudden increases indicate focus drift. Temperature correlation helps predict when to refocus.',
    target: TourTarget.analyticsHfrChart,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'at_guiding_chart',
    title: 'Guiding Chart',
    description:
        'Review guiding performance throughout your session. Identify periods of poor seeing or mount issues. Correlate with image quality for best frames.',
    target: TourTarget.analyticsGuidingChart,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'at_thumbnails',
    title: 'Captured Images',
    description:
        'Browse thumbnails of all captured frames. Click any image for full-size view with metadata. Flag best frames or mark rejects for stacking.',
    target: TourTarget.analyticsThumbnails,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'at_complete',
    title: 'Data Insights',
    description:
        'Use Analytics to continuously improve! Track trends across sessions, identify optimal conditions, and refine your imaging technique over time.',
  ),
];

// Flat wizard tour (8 steps)
const List<TourStep> _flatWizardTour = [
  TourStep(
    id: 'fwt_welcome',
    title: 'Flat Frame Wizard',
    description:
        'The Flat Wizard automates flat frame capture. It calculates optimal exposure times and captures flats for all your filters with minimal effort.',
  ),
  TourStep(
    id: 'fwt_tabs',
    title: 'Capture Modes',
    description:
        'Choose between Sky Flats (twilight), Panel Flats (light panel), or Manual mode. Each mode optimizes the workflow for your flat source.',
    target: TourTarget.flatModeTabs,
    side: TourCardSide.bottom,
  ),
  TourStep(
    id: 'fwt_filter_select',
    title: 'Filter Selection',
    description:
        'Select which filters to capture flats for. The wizard captures flats in optimal order for sky flats (brightest to dimmest at dusk).',
    target: TourTarget.flatFilterSelect,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'fwt_target_adu',
    title: 'Target ADU',
    description:
        'Set the target brightness level for your flats. Typically 30-50% of your camera\'s full well capacity. The wizard adjusts exposure to hit this target.',
    target: TourTarget.flatTargetAdu,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'fwt_frame_count',
    title: 'Frame Count',
    description:
        'Specify how many flats to capture per filter. 20-30 flats per filter provides good signal for master flat creation.',
    target: TourTarget.flatFrameCount,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'fwt_preview',
    title: 'Preview Panel',
    description:
        'Watch the live preview as flats are captured. The histogram shows ADU distribution. Adjust exposure if the histogram isn\'t centered on your target.',
    target: TourTarget.flatPreview,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'fwt_start_btn',
    title: 'Start Capture',
    description:
        'Click Start to begin the flat capture sequence. The wizard handles exposure calculation, filter changes, and file naming automatically.',
    target: TourTarget.flatStartButton,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'fwt_complete',
    title: 'Flats Made Easy',
    description:
        'Flat frames are essential for clean images. Use the wizard at dusk or dawn for sky flats, or anytime with a flat panel. Consistent flats = better stacks!',
  ),
];

// Weather tour (8 steps)
const List<TourStep> _weatherTour = [
  TourStep(
    id: 'wt_welcome',
    title: 'Weather Monitoring',
    description:
        'The Weather screen provides detailed forecasting and real-time conditions. Plan sessions around clear skies and protect your equipment from incoming weather.',
  ),
  TourStep(
    id: 'wt_radar_map',
    title: 'Radar Map',
    description:
        'Live radar shows precipitation and cloud cover in your area. The animation shows movement direction. Plan around approaching systems.',
    target: TourTarget.weatherRadarMap,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'wt_timeline',
    title: 'Timeline',
    description:
        'Scrub through the forecast timeline to see predicted conditions hour by hour. Find the optimal imaging window for tonight.',
    target: TourTarget.weatherTimeline,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'wt_status_card',
    title: 'Conditions',
    description:
        'Current conditions at a glance: temperature, humidity, dew point, wind, and cloud cover. The imaging safety indicator shows if conditions are favorable.',
    target: TourTarget.weatherStatusCard,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'wt_alert_radius',
    title: 'Alert Radius',
    description:
        'Set the distance at which approaching weather triggers alerts. Smaller radius for permanent setups, larger for time to pack up portable gear.',
    target: TourTarget.weatherAlertRadius,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'wt_cloud_motion',
    title: 'Cloud Motion',
    description:
        'AI-powered cloud motion analysis predicts when clouds will reach your location. Get advance warning before conditions deteriorate.',
    target: TourTarget.weatherCloudMotion,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'wt_refresh_btn',
    title: 'Refresh',
    description:
        'Manually refresh weather data. Automatic updates occur every 15 minutes, but you can force an update when conditions are changing rapidly.',
    target: TourTarget.weatherRefreshButton,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'wt_complete',
    title: 'Weather Aware',
    description:
        'Stay ahead of the weather! Configure alerts in Settings to automatically pause sequences when conditions threaten. Protect your gear and optimize imaging time.',
  ),
];

// Settings tour (10 steps)
const List<TourStep> _settingsTour = [
  TourStep(
    id: 'stt_welcome',
    title: 'Application Settings',
    description:
        'Configure Skotiq to match your setup and preferences. Location, file paths, plate solving, and appearance options are all here.',
  ),
  TourStep(
    id: 'stt_categories',
    title: 'Categories',
    description:
        'Settings are organized into categories. Click any category to view and modify its options. Changes save automatically.',
    target: TourTarget.settingsCategories,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'stt_connection',
    title: 'Connection',
    description:
        'Configure how Skotiq connects to equipment. Set ASCOM/INDI/Alpaca preferences, network timeouts, and auto-reconnect behavior.',
    target: TourTarget.settingsConnection,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'stt_location',
    title: 'Location',
    description:
        'Set your observatory coordinates. Accurate location is essential for planetarium calculations, altitude predictions, and meridian flip timing.',
    target: TourTarget.settingsLocation,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'stt_appearance',
    title: 'Appearance',
    description:
        'Customize the look and feel. Choose dark or light themes, accent colors, and font sizes. Night mode preserves your dark adaptation.',
    target: TourTarget.settingsAppearance,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'stt_file_paths',
    title: 'File Paths',
    description:
        'Configure where images are saved. Set up folder structures with date, target, and filter substitutions. Keep your image library organized.',
    target: TourTarget.settingsFilePaths,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'stt_plate_solving',
    title: 'Plate Solving',
    description:
        'Configure your plate solver. Set paths to solver binaries, index files, and search parameters. Local solving is faster than online services.',
    target: TourTarget.settingsPlateSolving,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'stt_notifications',
    title: 'Notifications',
    description:
        'Control when and how Skotiq alerts you. Set up email, SMS, or push notifications for sequence completion, errors, or weather alerts.',
    target: TourTarget.settingsNotifications,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'stt_help',
    title: 'Help & Tutorials',
    description:
        'Access all tutorials from here. Reset tutorial progress, view documentation, or contact support. Tutorials can be replayed anytime.',
    target: TourTarget.settingsHelp,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'stt_complete',
    title: 'Personalized',
    description:
        'Skotiq is now configured to your preferences! Revisit Settings anytime to fine-tune your experience as you discover what works best.',
  ),
];

// Polar alignment tour (10 steps)
const List<TourStep> _polarAlignmentTour = [
  TourStep(
    id: 'pat_welcome',
    title: 'Polar Alignment',
    description:
        'The Polar Alignment wizard helps you achieve accurate polar alignment using plate solving. No need for a polar scope - just follow the guided process.',
  ),
  TourStep(
    id: 'pat_hemisphere',
    title: 'Hemisphere',
    description:
        'The pole you align on comes from your observing location: the north celestial pole near Polaris for a northern site, the south pole near Sigma Octantis for a southern one.',
    target: TourTarget.polarHemisphere,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'pat_exposure',
    title: 'Exposure Time',
    description:
        'Set the exposure time for measurement images. Longer exposures improve accuracy but take more time. 2-5 seconds usually works well.',
    target: TourTarget.polarExposure,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'pat_step_size',
    title: 'Step Size',
    description:
        'The mount rotation between measurements. Larger steps are faster but less precise. 30 degrees is a good starting point.',
    target: TourTarget.polarStepSize,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'pat_start_btn',
    title: 'Start',
    description:
        'Begin the alignment process. Skotiq will take images, rotate the mount, and calculate your polar alignment error.',
    target: TourTarget.polarStartButton,
    side: TourCardSide.right,
  ),
  TourStep(
    id: 'pat_image_view',
    title: 'Measurement',
    description:
        'Watch as Skotiq captures and plate solves images. Each solve refines the polar alignment calculation. The process typically takes 2-3 images.',
    target: TourTarget.polarImageView,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'pat_error_display',
    title: 'Error Display',
    description:
        'Your polar alignment error in arcminutes. For visual observing, under 10\' is fine. For imaging, aim for under 2\' for excellent tracking.',
    target: TourTarget.polarErrorDisplay,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'pat_adjustment',
    title: 'Adjustment Guide',
    description:
        'Follow the arrows to adjust your mount\'s altitude and azimuth knobs. The display updates in real-time as you make adjustments.',
    target: TourTarget.polarAdjustment,
    side: TourCardSide.left,
  ),
  TourStep(
    id: 'pat_progress',
    title: 'Progress Steps',
    description:
        'Track your progress through the alignment process. Each step shows completion status. Re-measure after adjustments to verify improvement.',
    target: TourTarget.polarProgress,
    side: TourCardSide.top,
  ),
  TourStep(
    id: 'pat_complete',
    title: 'Alignment Complete',
    description:
        'Great polar alignment means better tracking and easier guiding. Re-run the wizard periodically if your setup isn\'t permanent.',
  ),
];
