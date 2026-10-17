// Dashboard through sequencer screen-tour definitions.
part of '../tutorial_models.dart';

// Dashboard tour (12 steps)
const List<TutorialStep> _dashboardTour = [
  TutorialStep(
    id: 'dt_welcome',
    title: 'Welcome to Dashboard',
    description:
        'The Dashboard is your mission control for astrophotography. It provides an at-a-glance view of all active systems and lets you customize the layout to match your workflow.',
    position: TooltipPosition.center,
    order: 0,
    category: TutorialCategory.dashboardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'dt_edit_button',
    title: 'Customize Layout',
    description:
        'Click the Edit button to rearrange dashboard widgets. Drag widgets to reorder them, resize panels, or hide ones you don\'t need. Your layout is saved automatically.',
    targetKey: 'dashboard_edit_button',
    position: TooltipPosition.bottom,
    order: 1,
    category: TutorialCategory.dashboardTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'dt_live_preview',
    title: 'Live Image Preview',
    description:
        'This panel shows your latest captured image with real-time updates during exposures. Use pinch to zoom and pan to inspect details.',
    targetKey: 'dashboard_live_preview',
    position: TooltipPosition.left,
    order: 2,
    category: TutorialCategory.dashboardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'dt_capture_controls',
    title: 'Quick Capture',
    description:
        'Take snapshots or start loop exposures directly from the Dashboard without navigating away. Perfect for quick focus checks or framing adjustments.',
    targetKey: 'dashboard_capture_controls',
    position: TooltipPosition.left,
    order: 3,
    category: TutorialCategory.dashboardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'dt_session_widget',
    title: 'Session Progress',
    description:
        'Track your current imaging session: total frames captured, integration time accumulated, and estimated time remaining. Click to view detailed session statistics.',
    targetKey: 'dashboard_session_widget',
    position: TooltipPosition.left,
    order: 4,
    category: TutorialCategory.dashboardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'dt_weather_widget',
    title: 'Weather Status',
    description:
        'Monitor current weather conditions including cloud cover, humidity, and approaching weather systems. Alerts appear here when conditions threaten your imaging session.',
    targetKey: 'dashboard_weather_widget',
    position: TooltipPosition.left,
    order: 5,
    category: TutorialCategory.dashboardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'dt_guiding_widget',
    title: 'Guiding Status',
    description:
        'View real-time guiding performance from PHD2. The graph shows RA/Dec errors, and RMS values indicate tracking accuracy. Green means excellent guiding.',
    targetKey: 'dashboard_guiding_widget',
    position: TooltipPosition.left,
    order: 6,
    category: TutorialCategory.dashboardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'dt_mount_widget',
    title: 'Mount Position',
    description:
        'See your mount\'s current coordinates, tracking status, and pier side. Quick slew controls let you center objects or park the mount without leaving the Dashboard.',
    targetKey: 'dashboard_mount_widget',
    position: TooltipPosition.left,
    order: 7,
    category: TutorialCategory.dashboardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'dt_focuser_widget',
    title: 'Focuser Control',
    description:
        'Monitor focus position and temperature. Run autofocus routines or make manual adjustments. The temperature compensation feature keeps focus sharp as the night cools.',
    targetKey: 'dashboard_focuser_widget',
    position: TooltipPosition.left,
    order: 8,
    category: TutorialCategory.dashboardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'dt_equipment_status',
    title: 'Equipment Overview',
    description:
        'See connection status for all your devices at a glance. Green indicates connected, red means disconnected. Click any device to jump to its detailed controls.',
    targetKey: 'dashboard_equipment_status',
    position: TooltipPosition.left,
    order: 9,
    category: TutorialCategory.dashboardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'dt_sequence_widget',
    title: 'Active Sequence',
    description:
        'When a sequence is running, this widget shows current progress, active target, and remaining time. Pause or abort the sequence directly from here.',
    targetKey: 'dashboard_sequence_widget',
    position: TooltipPosition.left,
    order: 10,
    category: TutorialCategory.dashboardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'dt_complete',
    title: 'Dashboard Complete',
    description:
        'You\'ve learned the Dashboard basics! Customize the layout to fit your workflow. The Dashboard adapts to show what matters most during your imaging sessions.',
    position: TooltipPosition.center,
    order: 11,
    category: TutorialCategory.dashboardTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// Equipment tour (10 steps)
const List<TutorialStep> _equipmentTour = [
  TutorialStep(
    id: 'et_welcome',
    title: 'Equipment Management',
    description:
        'The Equipment screen is where you configure and connect all your astrophotography gear. Create profiles to quickly switch between different setups.',
    position: TooltipPosition.center,
    order: 0,
    category: TutorialCategory.equipmentTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'et_profile_selector',
    title: 'Equipment Profiles',
    description:
        'Select from saved equipment profiles. Each profile stores your telescope, camera, and accessory configurations. Switch profiles when changing imaging rigs.',
    targetKey: 'equipment_profile_selector',
    position: TooltipPosition.bottom,
    order: 1,
    category: TutorialCategory.equipmentTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'et_create_profile',
    title: 'Create Profile',
    description:
        'Click to create a new equipment profile. Enter your sensor dimensions, pixel size, and focal length to enable accurate field-of-view calculations throughout Skotiq.',
    targetKey: 'equipment_create_profile_btn',
    position: TooltipPosition.bottom,
    order: 2,
    category: TutorialCategory.equipmentTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'et_quick_connect',
    title: 'Quick Connect',
    description:
        'The Quick Connect bar shows your most-used devices. Click a device icon to instantly connect or disconnect. Green means connected, gray means available.',
    targetKey: 'equipment_quick_connect_bar',
    position: TooltipPosition.bottom,
    order: 3,
    category: TutorialCategory.equipmentTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'et_discovery_tab',
    title: 'Device Discovery',
    description:
        'The Discovery tab scans for available devices. It can find Windows ASCOM COM drivers, configured or reachable INDI servers, and Alpaca devices on your network when those backends are in scope for the release.',
    targetKey: 'equipment_discovery_tab',
    position: TooltipPosition.bottom,
    order: 4,
    category: TutorialCategory.equipmentTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'et_connected_tab',
    title: 'Connected Devices',
    description:
        'View all currently connected devices here. Each device shows its status, and you can access detailed settings by clicking on it.',
    targetKey: 'equipment_connected_tab',
    position: TooltipPosition.bottom,
    order: 5,
    category: TutorialCategory.equipmentTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'et_settings_tab',
    title: 'Device Settings',
    description:
        'Configure advanced device settings here. Set default gain, offset, cooling targets for cameras, or tracking rates for mounts.',
    targetKey: 'equipment_settings_tab',
    position: TooltipPosition.bottom,
    order: 6,
    category: TutorialCategory.equipmentTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'et_camera_card',
    title: 'Camera Controls',
    description:
        'Your camera\'s detailed settings: gain, offset, binning, readout mode, and cooling. Set the target temperature and watch the cooler reach equilibrium.',
    targetKey: 'equipment_camera_card',
    position: TooltipPosition.left,
    order: 7,
    category: TutorialCategory.equipmentTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'et_mount_card',
    title: 'Mount Controls',
    description:
        'Mount settings include tracking rate, guide rate, and slew speed. Park positions, home commands, and meridian flip settings are configured here.',
    targetKey: 'equipment_mount_card',
    position: TooltipPosition.left,
    order: 8,
    category: TutorialCategory.equipmentTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'et_complete',
    title: 'Equipment Ready',
    description:
        'You\'re now familiar with equipment management! Create profiles for each of your setups and use Quick Connect for fast session startup.',
    position: TooltipPosition.center,
    order: 9,
    category: TutorialCategory.equipmentTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// Imaging tour (15 steps)
const List<TutorialStep> _imagingTour = [
  TutorialStep(
    id: 'it_welcome',
    title: 'The Imaging Screen',
    description:
        'The Imaging screen is your primary interface for capturing images. Control your camera, view live images, and monitor image quality all in one place.',
    position: TooltipPosition.center,
    order: 0,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'it_tab_bar',
    title: 'Navigation Tabs',
    description:
        'Switch between Capture, Mount, and Focus tabs. Each tab provides specialized controls for different aspects of your imaging workflow.',
    targetKey: 'imaging_tab_bar',
    position: TooltipPosition.bottom,
    order: 1,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'it_preview_area',
    title: 'Image Preview',
    description:
        'Your captured images appear here with auto-stretch applied. Pinch to zoom, drag to pan, and double-tap to reset the view. The crosshair marks the image center.',
    targetKey: 'imaging_preview_area',
    position: TooltipPosition.left,
    order: 2,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'it_zoom_controls',
    title: 'Zoom Controls',
    description:
        'Zoom in to inspect star shapes and check focus. The 1:1 button shows actual pixels. Use zoom during focusing to see the tightest star shapes.',
    targetKey: 'imaging_zoom_controls',
    position: TooltipPosition.left,
    order: 3,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'it_exposure_slider',
    title: 'Exposure Time',
    description:
        'Set your exposure duration here. For focusing, use short exposures (1-3 seconds). For imaging, typical exposures range from 60-300 seconds depending on your target.',
    targetKey: 'imaging_exposure_slider',
    position: TooltipPosition.right,
    order: 4,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'it_gain_control',
    title: 'Gain Setting',
    description:
        'Adjust camera gain (sensitivity). Higher gain means brighter images but more noise. Find your camera\'s unity gain or optimal gain for best results.',
    targetKey: 'imaging_gain_control',
    position: TooltipPosition.right,
    order: 5,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'it_filter_selector',
    title: 'Filter Selection',
    description:
        'Choose the active filter from your filter wheel. Skotiq remembers focus offsets for each filter and applies them automatically.',
    targetKey: 'imaging_filter_selector',
    position: TooltipPosition.right,
    order: 6,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'it_snapshot_btn',
    title: 'Snapshot Button',
    description:
        'Take a single exposure with current settings. The image appears in the preview when complete. Use snapshots for framing and focus checks.',
    targetKey: 'imaging_snapshot_btn',
    position: TooltipPosition.top,
    order: 7,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'it_loop_btn',
    title: 'Loop Capture',
    description:
        'Start continuous exposures that repeat until stopped. Essential for focusing — watch the stars tighten as you adjust. HFR updates with each frame.',
    targetKey: 'imaging_loop_btn',
    position: TooltipPosition.top,
    order: 8,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'it_abort_btn',
    title: 'Abort Button',
    description:
        'Stop the current exposure immediately. The partial image is discarded. Use this when you need to make quick adjustments.',
    targetKey: 'imaging_abort_btn',
    position: TooltipPosition.top,
    order: 9,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'it_stats_panel',
    title: 'Image Statistics',
    description:
        'View key metrics: HFR (star size), median ADU, detected stars, and more. Lower HFR means better focus. Watch these numbers during your session.',
    targetKey: 'imaging_stats_panel',
    position: TooltipPosition.left,
    order: 10,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'it_mount_tab',
    title: 'Mount Tab',
    description:
        'Access mount controls without leaving the Imaging screen. Slew to coordinates, sync position, or make fine adjustments while viewing your image.',
    targetKey: 'imaging_mount_tab',
    position: TooltipPosition.bottom,
    order: 11,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'it_focus_tab',
    title: 'Focus Tab',
    description:
        'Run autofocus routines or manually adjust focus position. The focus graph shows your V-curve. Temperature compensation keeps focus sharp all night.',
    targetKey: 'imaging_focus_tab',
    position: TooltipPosition.bottom,
    order: 12,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'it_histogram',
    title: 'Histogram',
    description:
        'The histogram shows the brightness distribution of your image. A well-exposed light frame should have the peak slightly left of center.',
    targetKey: 'imaging_histogram',
    position: TooltipPosition.top,
    order: 13,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'it_complete',
    title: 'Imaging Mastered',
    description:
        'You know the Imaging screen! Use Loop mode for focusing, check HFR for quality, and keep an eye on your histogram for proper exposure.',
    position: TooltipPosition.center,
    order: 14,
    category: TutorialCategory.imagingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// Guiding tour (10 steps)
const List<TutorialStep> _guidingTour = [
  TutorialStep(
    id: 'gt_welcome',
    title: 'PHD2 Guiding',
    description:
        'The Guiding screen connects to PHD2 for autoguiding. Monitor guide star tracking, view correction graphs, and control guiding directly from Skotiq.',
    position: TooltipPosition.center,
    order: 0,
    category: TutorialCategory.guidingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'gt_connect_btn',
    title: 'Connect to PHD2',
    description:
        'Click to connect to PHD2. Ensure PHD2 is running and its server is enabled. Once connected, Skotiq can start/stop guiding and receive performance data.',
    targetKey: 'guiding_connect_btn',
    position: TooltipPosition.bottom,
    order: 1,
    category: TutorialCategory.guidingTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'gt_status_bar',
    title: 'Connection Status',
    description:
        'Shows the current PHD2 connection state and guiding status. Green means actively guiding, yellow means calibrating, red indicates an issue.',
    targetKey: 'guiding_status_bar',
    position: TooltipPosition.bottom,
    order: 2,
    category: TutorialCategory.guidingTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'gt_star_view',
    title: 'Guide Star View',
    description:
        'See your guide star in real-time. The crosshair shows the lock position. A stable, non-saturated star makes the best guide star.',
    targetKey: 'guiding_star_view',
    position: TooltipPosition.left,
    order: 3,
    category: TutorialCategory.guidingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'gt_target_display',
    title: 'Target Display',
    description:
        'The target shows guide corrections as dots. Tight clustering near center indicates excellent guiding. Spread-out dots suggest issues to investigate.',
    targetKey: 'guiding_target_display',
    position: TooltipPosition.left,
    order: 4,
    category: TutorialCategory.guidingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'gt_graph',
    title: 'Guiding Graph',
    description:
        'The graph shows RA (blue) and Dec (red) corrections over time. Flat lines near zero mean perfect tracking. Regular patterns may indicate periodic error.',
    targetKey: 'guiding_graph',
    position: TooltipPosition.top,
    order: 5,
    category: TutorialCategory.guidingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'gt_rms_display',
    title: 'RMS Statistics',
    description:
        'RMS values quantify guiding accuracy in arcseconds. Lower is better. Under 1" total RMS is excellent for most setups. Watch for trends over time.',
    targetKey: 'guiding_rms_display',
    position: TooltipPosition.left,
    order: 6,
    category: TutorialCategory.guidingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'gt_controls',
    title: 'Guiding Controls',
    description:
        'Start, stop, and pause guiding. Dither between exposures for better stacking. These controls sync with your active sequence automatically.',
    targetKey: 'guiding_controls',
    position: TooltipPosition.top,
    order: 7,
    category: TutorialCategory.guidingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'gt_brain_btn',
    title: 'PHD2 Brain',
    description:
        'Open PHD2\'s advanced settings (the "Brain"). Fine-tune guide algorithms, calibration settings, and more. Most users won\'t need to change these.',
    targetKey: 'guiding_brain_btn',
    position: TooltipPosition.left,
    order: 8,
    category: TutorialCategory.guidingTour,
    spotlightShape: SpotlightShape.circle,
  ),
  TutorialStep(
    id: 'gt_complete',
    title: 'Guiding Ready',
    description:
        'You understand the Guiding screen! For best results, select a bright but unsaturated guide star and aim for sub-arcsecond RMS values.',
    position: TooltipPosition.center,
    order: 9,
    category: TutorialCategory.guidingTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];

// Sequencer tour (12 steps)
const List<TutorialStep> _sequencerTour = [
  TutorialStep(
    id: 'st_welcome',
    title: 'The Sequencer',
    description:
        'The Sequencer automates your entire imaging session. Build sequences with drag-and-drop, save templates, and let Skotiq image all night unattended.',
    position: TooltipPosition.center,
    order: 0,
    category: TutorialCategory.sequencerTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'st_tab_builder',
    title: 'Builder Tab',
    description:
        'Create and edit sequences in the Builder. Drag nodes from the palette onto the canvas, connect them, and configure each step of your workflow.',
    targetKey: 'sequencer_tab_builder',
    position: TooltipPosition.bottom,
    order: 1,
    category: TutorialCategory.sequencerTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'st_tab_templates',
    title: 'Templates Tab',
    description:
        'Browse built-in Starters and your saved templates. Tap a Starter to load a complete, ready-to-run sequence, or save your own workflows like LRGB imaging, narrowband, or quick snapshots for reuse.',
    targetKey: 'sequencer_tab_templates',
    position: TooltipPosition.bottom,
    order: 2,
    category: TutorialCategory.sequencerTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'st_node_palette',
    title: 'Node Palette',
    description:
        'Drag nodes from here onto the canvas. Choose from Target nodes, Capture nodes, Autofocus, Filter changes, Dither, and more.',
    targetKey: 'sequencer_node_palette',
    position: TooltipPosition.right,
    order: 3,
    category: TutorialCategory.sequencerTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'st_canvas',
    title: 'Sequence Canvas',
    description:
        'Build your sequence visually. Connect nodes to define execution flow. The sequence runs top-to-bottom, branching where you connect multiple paths.',
    targetKey: 'sequencer_canvas',
    position: TooltipPosition.left,
    order: 4,
    category: TutorialCategory.sequencerTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'st_target_node',
    title: 'Target Nodes',
    description:
        'Target nodes slew to objects and center using plate solving. Add coordinates manually or import from the Planetarium or Framing screens.',
    targetKey: 'sequencer_target_node',
    position: TooltipPosition.left,
    order: 5,
    category: TutorialCategory.sequencerTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'st_capture_node',
    title: 'Capture Nodes',
    description:
        'Capture nodes take your images. Configure filter, exposure, gain, and frame count. Add multiple Capture nodes for multi-filter imaging.',
    targetKey: 'sequencer_capture_node',
    position: TooltipPosition.left,
    order: 6,
    category: TutorialCategory.sequencerTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'st_properties_panel',
    title: 'Properties Panel',
    description:
        'Select any node to view and edit its properties here. Set exposure times, filter selections, loop counts, and advanced options.',
    targetKey: 'sequencer_properties_panel',
    position: TooltipPosition.left,
    order: 7,
    category: TutorialCategory.sequencerTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'st_toolbar',
    title: 'Sequence Toolbar',
    description:
        'Control sequence execution from the toolbar. Play starts the sequence, Pause holds execution, and Stop ends the session. Save your sequences frequently!',
    targetKey: 'sequencer_toolbar',
    position: TooltipPosition.bottom,
    order: 8,
    category: TutorialCategory.sequencerTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
  TutorialStep(
    id: 'st_progress_bar',
    title: 'Progress Indicator',
    description:
        'Track sequence progress here. See completed, current, and remaining steps. Estimated completion time updates based on actual performance.',
    targetKey: 'sequencer_progress_bar',
    position: TooltipPosition.top,
    order: 9,
    category: TutorialCategory.sequencerTour,
    spotlightShape: SpotlightShape.pill,
  ),
  TutorialStep(
    id: 'st_complete',
    title: 'Sequencer Expert',
    description:
        'You\'ve mastered the Sequencer! Build sequences for unattended imaging, save templates for quick setup, and let Skotiq do the work.',
    position: TooltipPosition.center,
    order: 10,
    category: TutorialCategory.sequencerTour,
    spotlightShape: SpotlightShape.roundedRect,
  ),
];
