#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
// EXTRA BEGIN
typedef struct DartCObject *WireSyncRust2DartDco;
typedef struct WireSyncRust2DartSse {
  uint8_t *ptr;
  int32_t len;
} WireSyncRust2DartSse;

typedef int64_t DartPort;
typedef bool (*DartPostCObjectFnType)(DartPort port_id, void *message);
void store_dart_post_cobject(DartPostCObjectFnType ptr);
// EXTRA END
typedef struct _Dart_Handle* Dart_Handle;

/**
 * The `SensorType` ordinal for an RGGB-family colour-filter array, the one
 * family whose element order [`BayerPattern`] can name.
 */
#define SENSOR_TYPE_RGGB 2

/**
 * Jobs waiting behind the one in flight. Frames arrive one per exposure
 * (tens of seconds apart) and a job takes about a second per goal, so a
 * backlog this deep means analysis is not keeping up and shedding is the
 * right answer.
 */
#define QUEUE_CAPACITY 8

/**
 * Default event buffer size: 4096 broadcast slots, enough for the burstiest
 * producers (autofocus loops, 10 Hz guiding corrections). A receiver that falls
 * further behind than this gets `Lagged` and skips to the latest events.
 */
#define DEFAULT_EVENT_BUFFER_SIZE 4096

/**
 * Simulated sensor dimensions.
 *
 * This is THE sensor. `SimulatedCamera::default` and
 * `device_capabilities::get_simulator_capabilities` declare these same numbers,
 * so the frame a caller receives matches the geometry the camera advertised and
 * a measurement taken through one capture path is comparable with the other.
 */
#define SIM_W 1920

#define SIM_H 1080

/**
 * Full-well ceiling of the simulated sensor, in ADU.
 */
#define SIM_MAX_ADU 65535

/**
 * Focuser position at which simulated stars are sharpest.
 *
 * Chosen to sit INSIDE the default autofocus sweep but off its centre. The
 * focuser starts at 25000 and the default sweep spans roughly +/-200 steps, so:
 *   * putting true focus at the centre (25000) would let an algorithm that never
 *     moved appear to succeed, and
 *   * putting it at the edge (25200, tried first) gives the sweep a monotonic
 *     slope instead of a V — the parabola fit then degenerates and autofocus
 *     correctly refuses it with "curve fit R² 0.000 is below 0.700".
 *
 * 25075 brackets the minimum on both sides while still requiring real movement.
 */
#define SIM_TRUE_FOCUS 25075

/**
 * Exposure used by the parameterless convenience constructor.
 */
#define SIM_DEFAULT_EXPOSURE_SECS 10.0

/**
 * How many catalogue stars a real-sky frame renders, brightest first.
 */
#define SIM_SKY_STAR_LIMIT 1500

typedef struct wire_cst_list_prim_u_8_strict {
  uint8_t *ptr;
  int32_t len;
} wire_cst_list_prim_u_8_strict;

typedef struct wire_cst_stretch_params_api {
  double shadows;
  double highlights;
  double midtones;
} wire_cst_stretch_params_api;

typedef struct wire_cst_list_prim_u_16_loose {
  uint16_t *ptr;
  int32_t len;
} wire_cst_list_prim_u_16_loose;

typedef struct wire_cst_list_String {
  struct wire_cst_list_prim_u_8_strict **ptr;
  int32_t len;
} wire_cst_list_String;

typedef struct wire_cst_list_prim_u_16_strict {
  uint16_t *ptr;
  int32_t len;
} wire_cst_list_prim_u_16_strict;

typedef struct wire_cst_api_combine_method {
  struct wire_cst_list_prim_u_8_strict *method;
  double *sigma_kappa;
  uint32_t *sigma_iterations;
} wire_cst_api_combine_method;

typedef struct wire_cst_api_sky_rectangle {
  double ra_deg;
  double dec_deg;
  double width_arcsec;
  double height_arcsec;
  double rotation_deg;
} wire_cst_api_sky_rectangle;

typedef struct wire_cst_api_depth_measurement {
  struct wire_cst_api_sky_rectangle region;
  struct wire_cst_api_sky_rectangle background;
  double scale_arcsec;
  double threshold;
  double min_coverage;
  double systematic_floor_adu;
  struct wire_cst_list_prim_u_8_strict *systematic_floor_source;
} wire_cst_api_depth_measurement;

typedef struct wire_cst_api_reference_geometry {
  uint32_t width;
  uint32_t height;
  double crval1;
  double crval2;
  double crpix1;
  double crpix2;
  double cd1_1;
  double cd1_2;
  double cd2_1;
  double cd2_2;
} wire_cst_api_reference_geometry;

typedef struct wire_cst_api_acquisition_settings {
  struct wire_cst_list_prim_u_8_strict *instrument;
  struct wire_cst_list_prim_u_8_strict *filter;
  double exposure_secs;
  int32_t *gain;
  int32_t *offset;
  int32_t bin_x;
  int32_t bin_y;
  double *ccd_temp_c;
} wire_cst_api_acquisition_settings;

typedef struct wire_cst_api_depth_goal_definition {
  struct wire_cst_list_prim_u_8_strict *label;
  struct wire_cst_list_prim_u_8_strict *project_id;
  struct wire_cst_list_prim_u_8_strict *target_id;
  struct wire_cst_list_prim_u_8_strict *profile_id;
  struct wire_cst_list_prim_u_8_strict *filter_name;
  int32_t *filter_index;
  struct wire_cst_list_prim_u_8_strict *reference_path;
  struct wire_cst_api_reference_geometry reference;
  struct wire_cst_api_acquisition_settings acquisition;
  double temperature_tolerance_c;
  struct wire_cst_list_prim_u_8_strict *dark_path;
  struct wire_cst_list_prim_u_8_strict *flat_path;
  struct wire_cst_api_depth_measurement measurement;
  bool enabled;
  bool automatic_completion;
} wire_cst_api_depth_goal_definition;

typedef struct wire_cst_star_detection_config_api {
  double detection_sigma;
  uint32_t min_area;
  uint32_t max_area;
  double max_eccentricity;
  uint32_t saturation_limit;
  uint32_t hfr_radius;
  double *min_hfr;
  double *min_snr;
  double *max_sharpness;
} wire_cst_star_detection_config_api;

typedef struct wire_cst_plate_solver_config_payload {
  struct wire_cst_list_prim_u_8_strict *astap_path;
  struct wire_cst_list_prim_u_8_strict *astrometry_path;
  struct wire_cst_list_prim_u_8_strict *catalog_path;
  struct wire_cst_list_prim_u_8_strict *solver_choice;
} wire_cst_plate_solver_config_payload;

typedef struct wire_cst_autofocus_config_api {
  double exposure_time;
  int32_t step_size;
  int32_t steps_out;
  struct wire_cst_list_prim_u_8_strict *method;
  int32_t binning;
  int32_t *gain;
  int32_t *offset;
  uint32_t number_of_attempts;
  uint32_t exposures_per_point;
  double r_squared_threshold;
  double outer_crop_ratio;
  double inner_crop_ratio;
  uint32_t use_brightest_n_stars;
  uint64_t focuser_settle_time_ms;
  struct wire_cst_list_prim_u_8_strict *backlash_comp_method;
  int32_t backlash_in;
  int32_t backlash_out;
  int32_t *measured_backlash_in;
} wire_cst_autofocus_config_api;

typedef struct wire_cst_indi_autofocus_config_api {
  struct wire_cst_list_prim_u_8_strict *method;
  int32_t step_size;
  uint32_t steps_out;
  double exposure_duration;
  int32_t backlash_compensation;
  bool use_temperature_prediction;
  double *max_star_count_change;
  double outlier_rejection_sigma;
  int32_t binning;
  uint64_t move_timeout_secs;
  uint64_t settling_time_ms;
} wire_cst_indi_autofocus_config_api;

typedef struct wire_cst_fits_write_header {
  struct wire_cst_list_prim_u_8_strict *object_name;
  double exposure_time;
  struct wire_cst_list_prim_u_8_strict *capture_timestamp;
  struct wire_cst_list_prim_u_8_strict *frame_type;
  struct wire_cst_list_prim_u_8_strict *filter;
  int32_t *gain;
  int32_t *offset;
  double *ccd_temp;
  double *ra;
  double *dec;
  double *altitude;
  struct wire_cst_list_prim_u_8_strict *telescope;
  struct wire_cst_list_prim_u_8_strict *instrument;
  struct wire_cst_list_prim_u_8_strict *observer;
  int32_t bin_x;
  int32_t bin_y;
  double *focal_length;
  double *aperture;
  double *pixel_size_x;
  double *pixel_size_y;
  double *site_latitude;
  double *site_longitude;
  double *site_elevation;
} wire_cst_fits_write_header;

typedef struct wire_cst_equipment_profile {
  struct wire_cst_list_prim_u_8_strict *id;
  struct wire_cst_list_prim_u_8_strict *name;
  struct wire_cst_list_prim_u_8_strict *camera_id;
  struct wire_cst_list_prim_u_8_strict *mount_id;
  struct wire_cst_list_prim_u_8_strict *focuser_id;
  struct wire_cst_list_prim_u_8_strict *filter_wheel_id;
  struct wire_cst_list_prim_u_8_strict *guider_id;
  struct wire_cst_list_prim_u_8_strict *rotator_id;
  struct wire_cst_list_prim_u_8_strict *dome_id;
  struct wire_cst_list_prim_u_8_strict *weather_id;
  struct wire_cst_list_prim_u_8_strict *safety_monitor_id;
  struct wire_cst_list_prim_u_8_strict *cover_calibrator_id;
  double telescope_focal_length;
  double telescope_aperture;
} wire_cst_equipment_profile;

typedef struct wire_cst_list_prim_u_8_loose {
  uint8_t *ptr;
  int32_t len;
} wire_cst_list_prim_u_8_loose;

typedef struct wire_cst_record_string_string {
  struct wire_cst_list_prim_u_8_strict *field0;
  struct wire_cst_list_prim_u_8_strict *field1;
} wire_cst_record_string_string;

typedef struct wire_cst_list_record_string_string {
  struct wire_cst_record_string_string *ptr;
  int32_t len;
} wire_cst_list_record_string_string;

typedef struct wire_cst_secondary_rig_config_api {
  struct wire_cst_list_prim_u_8_strict *camera_id;
  double exposure_secs;
  int32_t *gain;
  int32_t *offset;
  int32_t bin_x;
  int32_t bin_y;
  uint32_t *frame_count;
  struct wire_cst_list_prim_u_8_strict *filter_name;
  double *target_temp_c;
  struct wire_cst_list_prim_u_8_strict *rig_label;
  struct wire_cst_list_prim_u_8_strict *camera_make;
  struct wire_cst_list_prim_u_8_strict *camera_model;
  struct wire_cst_list_prim_u_8_strict *telescope_name;
  double *telescope_focal_length_mm;
  double *telescope_aperture_mm;
  double dither_max_wait_secs;
  struct wire_cst_list_prim_u_8_strict *in_flight_policy;
  struct wire_cst_list_prim_u_8_strict *save_base_path;
  struct wire_cst_list_prim_u_8_strict *target_name;
  double *target_ra_hours;
  double *target_dec_degrees;
  struct wire_cst_list_prim_u_8_strict *observer_name;
  double *site_latitude_deg;
  double *site_longitude_deg;
  double *site_elevation_m;
} wire_cst_secondary_rig_config_api;

typedef struct wire_cst_node_definition_api {
  struct wire_cst_list_prim_u_8_strict *id;
  struct wire_cst_list_prim_u_8_strict *name;
  struct wire_cst_list_prim_u_8_strict *node_type;
  bool enabled;
  struct wire_cst_list_String *children;
  struct wire_cst_list_prim_u_8_strict *config_json;
} wire_cst_node_definition_api;

typedef struct wire_cst_list_node_definition_api {
  struct wire_cst_node_definition_api *ptr;
  int32_t len;
} wire_cst_list_node_definition_api;

typedef struct wire_cst_sequence_definition_api {
  struct wire_cst_list_prim_u_8_strict *id;
  struct wire_cst_list_prim_u_8_strict *name;
  struct wire_cst_list_prim_u_8_strict *description;
  struct wire_cst_list_node_definition_api *nodes;
  struct wire_cst_list_prim_u_8_strict *root_node_id;
} wire_cst_sequence_definition_api;

typedef struct wire_cst_record_string_i_32 {
  struct wire_cst_list_prim_u_8_strict *field0;
  int32_t field1;
} wire_cst_record_string_i_32;

typedef struct wire_cst_list_record_string_i_32 {
  struct wire_cst_record_string_i_32 *ptr;
  int32_t len;
} wire_cst_list_record_string_i_32;

typedef struct wire_cst_list_bool {
  bool *ptr;
  int32_t len;
} wire_cst_list_bool;

typedef struct wire_cst_list_prim_f_64_loose {
  double *ptr;
  int32_t len;
} wire_cst_list_prim_f_64_loose;

typedef struct wire_cst_record_string_f_64 {
  struct wire_cst_list_prim_u_8_strict *field0;
  double field1;
} wire_cst_record_string_f_64;

typedef struct wire_cst_list_record_string_f_64 {
  struct wire_cst_record_string_f_64 *ptr;
  int32_t len;
} wire_cst_list_record_string_f_64;

typedef struct wire_cst_record_string_map_string_f_64_none {
  struct wire_cst_list_prim_u_8_strict *field0;
  struct wire_cst_list_record_string_f_64 *field1;
} wire_cst_record_string_map_string_f_64_none;

typedef struct wire_cst_list_record_string_map_string_f_64_none {
  struct wire_cst_record_string_map_string_f_64_none *ptr;
  int32_t len;
} wire_cst_list_record_string_map_string_f_64_none;

typedef struct wire_cst_recovery_config_update {
  double retry_interval_secs;
  double max_duration_secs;
  bool stop_tracking_during_recovery;
  bool abort_on_meridian;
  bool audible_alert_when_entered;
  bool park_and_close_when_recovery_gives_up;
} wire_cst_recovery_config_update;

typedef struct wire_cst_observer_location {
  double latitude;
  double longitude;
  double elevation;
} wire_cst_observer_location;

typedef struct wire_cst_api_live_stacking_config {
  bool sigma_clip_enabled;
  double sigma_clip_threshold;
  uint32_t max_match_stars;
  double match_radius_px;
  double match_flux_tolerance;
  uint32_t min_matched_pairs;
  struct wire_cst_list_prim_u_8_strict *sensor_mode;
  struct wire_cst_list_prim_u_8_strict *bayer_pattern;
  struct wire_cst_list_prim_u_8_strict *demosaic_quality;
} wire_cst_api_live_stacking_config;

typedef struct wire_cst_fits_keyword_update {
  struct wire_cst_list_prim_u_8_strict *keyword;
  struct wire_cst_list_prim_u_8_strict *comment;
  struct wire_cst_list_prim_u_8_strict *string_value;
  int64_t *int_value;
  double *float_value;
} wire_cst_fits_keyword_update;

typedef struct wire_cst_list_fits_keyword_update {
  struct wire_cst_fits_keyword_update *ptr;
  int32_t len;
} wire_cst_list_fits_keyword_update;

typedef struct wire_cst_app_settings {
  struct wire_cst_observer_location *location;
  struct wire_cst_list_prim_u_8_strict *theme;
  struct wire_cst_list_prim_u_8_strict *language;
  bool auto_connect;
} wire_cst_app_settings;

typedef struct wire_cst_fits_write_header_rich {
  struct wire_cst_list_prim_u_8_strict *object_name;
  double exposure_time;
  struct wire_cst_list_prim_u_8_strict *capture_timestamp;
  struct wire_cst_list_prim_u_8_strict *frame_type;
  struct wire_cst_list_prim_u_8_strict *filter;
  int32_t *filter_position;
  int32_t *gain;
  int32_t *offset;
  double *ccd_temp;
  double *set_temp;
  double *ra;
  double *dec;
  double *altitude;
  struct wire_cst_list_prim_u_8_strict *telescope;
  struct wire_cst_list_prim_u_8_strict *instrument;
  struct wire_cst_list_prim_u_8_strict *observer;
  int32_t bin_x;
  int32_t bin_y;
  double *focal_length;
  double *aperture;
  double *pixel_size_x;
  double *pixel_size_y;
  double *site_latitude;
  double *site_longitude;
  double *site_elevation;
  int32_t *focuser_position;
  double *focuser_temperature;
  double *rotator_angle;
  double *guide_rms_arcsec;
  double *solved_ra_hours;
  double *solved_dec_degrees;
  double *plate_solve_pixel_scale_arcsec;
  double *plate_solve_rotation_deg;
  struct wire_cst_list_prim_u_8_strict *bayer_pattern;
  struct wire_cst_list_prim_u_8_strict *session_id;
  uint32_t *frame_index;
  uint32_t *total_planned_frames;
  struct wire_cst_list_prim_u_8_strict *mosaic_name;
  int32_t *mosaic_panel_index;
  int32_t *mosaic_panel_row;
  int32_t *mosaic_panel_column;
  int32_t *mosaic_total_panels;
  uintptr_t *defect_map_correction;
  struct wire_cst_list_prim_u_8_strict *photometry_object_catalog;
  struct wire_cst_list_prim_u_8_strict *photometry_reference_stars;
  double *photometry_mjd_obs;
  double *photometry_instrumental_mag;
  double *photometry_differential_mag;
  double *photometry_fwhm_arcsec;
  double *photometry_snr;
  struct wire_cst_list_prim_u_8_strict *rig_label;
} wire_cst_fits_write_header_rich;

typedef struct wire_cst_api_defect_map_status {
  struct wire_cst_list_prim_u_8_strict *camera_id;
  uint32_t width;
  uint32_t height;
  int16_t temperature_bucket_decicelsius;
  uint32_t defective_pixel_count;
  int64_t last_rebuilt_unix_seconds;
  bool apply_during_capture;
  bool stored_on_disk;
} wire_cst_api_defect_map_status;

typedef struct wire_cst_api_depth_forecast {
  uint32_t frames_to_threshold;
  uint32_t frames_to_confirm;
  bool reachable;
  double ceiling_score;
  double per_frame_noise_adu;
  double recent_frame_noise_adu;
  double best_frame_noise_adu;
} wire_cst_api_depth_forecast;

typedef struct wire_cst_api_depth_report {
  struct wire_cst_list_prim_u_8_strict *state;
  double *score;
  double *conservative_score;
  double *uncertainty_adu;
  double coverage;
  uint32_t evidence_frames;
  uint32_t confirmation_frames;
  struct wire_cst_list_prim_u_8_strict *reason;
  struct wire_cst_api_depth_forecast *forecast;
} wire_cst_api_depth_report;

typedef struct wire_cst_camera_capabilities {
  uint32_t max_width;
  uint32_t max_height;
  uint32_t bit_depth;
  bool has_shutter;
  bool can_set_ccd_temperature;
  bool can_set_cooler;
  bool can_get_cooler_power;
  bool can_bin;
  int32_t max_bin_x;
  int32_t max_bin_y;
  bool can_asymmetric_bin;
  bool can_set_gain;
  int32_t *gain_min;
  int32_t *gain_max;
  bool can_set_offset;
  int32_t *offset_min;
  int32_t *offset_max;
  bool can_abort_exposure;
  bool can_stop_exposure;
  bool can_subframe;
  double *pixel_size_x;
  double *pixel_size_y;
  bool is_color;
  struct wire_cst_list_prim_u_8_strict *bayer_pattern;
  struct wire_cst_list_prim_u_8_strict *sensor_type;
  bool has_fast_readout;
  struct wire_cst_list_String *readout_modes;
  double *exposure_min;
  double *exposure_max;
  double *ccd_temperature;
  double *set_ccd_temperature;
  double *cooler_power;
  bool *cooler_on;
  double *cooler_min_temp_c;
  double *cooler_max_temp_c;
} wire_cst_camera_capabilities;

typedef struct wire_cst_checkpoint_info_api {
  struct wire_cst_list_prim_u_8_strict *sequence_name;
  struct wire_cst_list_prim_u_8_strict *timestamp;
  uint32_t completed_exposures;
  double completed_integration_secs;
  bool can_resume;
  int64_t age_seconds;
} wire_cst_checkpoint_info_api;

typedef struct wire_cst_cover_calibrator_capabilities {
  int32_t max_brightness;
  bool cover_present;
  bool calibrator_present;
  int32_t *cover_state;
  int32_t *calibrator_state;
  int32_t *brightness;
} wire_cst_cover_calibrator_capabilities;

typedef struct wire_cst_DepthLockEvent_GoalUpdated {
  struct wire_cst_list_prim_u_8_strict *goal_id;
  uint64_t revision;
  struct wire_cst_list_prim_u_8_strict *filter_name;
  struct wire_cst_list_prim_u_8_strict *state;
  double *score;
  double *conservative_score;
  double threshold;
  double *uncertainty_adu;
  double coverage;
  uint32_t evidence_frames;
  uint32_t confirmation_frames;
  struct wire_cst_list_prim_u_8_strict *reason;
  bool automatic_completion;
  uint32_t *frames_remaining;
  bool reachable;
} wire_cst_DepthLockEvent_GoalUpdated;

typedef struct wire_cst_DepthLockEvent_EvidenceRejected {
  struct wire_cst_list_prim_u_8_strict *goal_id;
  uint64_t revision;
  struct wire_cst_list_prim_u_8_strict *source_path;
  struct wire_cst_list_prim_u_8_strict *reason;
} wire_cst_DepthLockEvent_EvidenceRejected;

typedef struct wire_cst_DepthLockEvent_AnalysisDropped {
  struct wire_cst_list_prim_u_8_strict *source_path;
  struct wire_cst_list_prim_u_8_strict *reason;
} wire_cst_DepthLockEvent_AnalysisDropped;

typedef struct wire_cst_DepthLockEvent_GoalChanged {
  struct wire_cst_list_prim_u_8_strict *goal_id;
  uint64_t revision;
  struct wire_cst_list_prim_u_8_strict *change;
} wire_cst_DepthLockEvent_GoalChanged;

typedef union DepthLockEventKind {
  struct wire_cst_DepthLockEvent_GoalUpdated GoalUpdated;
  struct wire_cst_DepthLockEvent_EvidenceRejected EvidenceRejected;
  struct wire_cst_DepthLockEvent_AnalysisDropped AnalysisDropped;
  struct wire_cst_DepthLockEvent_GoalChanged GoalChanged;
} DepthLockEventKind;

typedef struct wire_cst_depth_lock_event {
  int32_t tag;
  union DepthLockEventKind kind;
} wire_cst_depth_lock_event;

typedef struct wire_cst_dome_capabilities {
  bool can_set_azimuth;
  bool can_park;
  bool can_find_home;
  bool can_set_shutter;
  bool can_sync_azimuth;
  double *azimuth;
  bool slewing;
  bool at_home;
  bool at_park;
  int32_t *shutter_status;
  bool can_slave;
  bool slaved;
  bool can_abort;
} wire_cst_dome_capabilities;

typedef struct wire_cst_EquipmentEvent_Connecting {
  struct wire_cst_list_prim_u_8_strict *device_type;
  struct wire_cst_list_prim_u_8_strict *device_id;
} wire_cst_EquipmentEvent_Connecting;

typedef struct wire_cst_EquipmentEvent_Connected {
  struct wire_cst_list_prim_u_8_strict *device_type;
  struct wire_cst_list_prim_u_8_strict *device_id;
} wire_cst_EquipmentEvent_Connected;

typedef struct wire_cst_EquipmentEvent_Disconnected {
  struct wire_cst_list_prim_u_8_strict *device_type;
  struct wire_cst_list_prim_u_8_strict *device_id;
} wire_cst_EquipmentEvent_Disconnected;

typedef struct wire_cst_EquipmentEvent_PropertyChanged {
  struct wire_cst_list_prim_u_8_strict *device_type;
  struct wire_cst_list_prim_u_8_strict *device_id;
  struct wire_cst_list_prim_u_8_strict *property;
  struct wire_cst_list_prim_u_8_strict *value;
} wire_cst_EquipmentEvent_PropertyChanged;

typedef struct wire_cst_EquipmentEvent_Error {
  struct wire_cst_list_prim_u_8_strict *device_type;
  struct wire_cst_list_prim_u_8_strict *device_id;
  struct wire_cst_list_prim_u_8_strict *message;
} wire_cst_EquipmentEvent_Error;

typedef struct wire_cst_EquipmentEvent_MountSlewStarted {
  double ra;
  double dec;
} wire_cst_EquipmentEvent_MountSlewStarted;

typedef struct wire_cst_EquipmentEvent_MountSlewCompleted {
  double ra;
  double dec;
} wire_cst_EquipmentEvent_MountSlewCompleted;

typedef struct wire_cst_EquipmentEvent_FocuserMoveStarted {
  int32_t target_position;
} wire_cst_EquipmentEvent_FocuserMoveStarted;

typedef struct wire_cst_EquipmentEvent_FocuserMoveCompleted {
  int32_t position;
} wire_cst_EquipmentEvent_FocuserMoveCompleted;

typedef struct wire_cst_EquipmentEvent_FocuserTemperatureChanged {
  double temperature;
} wire_cst_EquipmentEvent_FocuserTemperatureChanged;

typedef struct wire_cst_EquipmentEvent_FilterChanging {
  int32_t from_position;
  int32_t to_position;
  struct wire_cst_list_prim_u_8_strict *filter_name;
} wire_cst_EquipmentEvent_FilterChanging;

typedef struct wire_cst_EquipmentEvent_FilterChanged {
  int32_t position;
  struct wire_cst_list_prim_u_8_strict *filter_name;
} wire_cst_EquipmentEvent_FilterChanged;

typedef struct wire_cst_EquipmentEvent_RotatorMoveStarted {
  double target_angle;
} wire_cst_EquipmentEvent_RotatorMoveStarted;

typedef struct wire_cst_EquipmentEvent_RotatorMoveCompleted {
  double angle;
} wire_cst_EquipmentEvent_RotatorMoveCompleted;

typedef struct wire_cst_EquipmentEvent_CameraCoolingStarted {
  double target_temp;
} wire_cst_EquipmentEvent_CameraCoolingStarted;

typedef struct wire_cst_EquipmentEvent_CameraCoolingReached {
  double temperature;
} wire_cst_EquipmentEvent_CameraCoolingReached;

typedef struct wire_cst_EquipmentEvent_HeartbeatStarted {
  struct wire_cst_list_prim_u_8_strict *device_type;
  struct wire_cst_list_prim_u_8_strict *device_id;
  uint64_t interval_secs;
} wire_cst_EquipmentEvent_HeartbeatStarted;

typedef struct wire_cst_EquipmentEvent_HeartbeatStopped {
  struct wire_cst_list_prim_u_8_strict *device_type;
  struct wire_cst_list_prim_u_8_strict *device_id;
} wire_cst_EquipmentEvent_HeartbeatStopped;

typedef struct wire_cst_EquipmentEvent_HeartbeatStatusChanged {
  struct wire_cst_list_prim_u_8_strict *device_type;
  struct wire_cst_list_prim_u_8_strict *device_id;
  int32_t status;
  uint32_t consecutive_failures;
  uint64_t *last_rtt_ms;
} wire_cst_EquipmentEvent_HeartbeatStatusChanged;

typedef struct wire_cst_EquipmentEvent_HeartbeatReconnecting {
  struct wire_cst_list_prim_u_8_strict *device_type;
  struct wire_cst_list_prim_u_8_strict *device_id;
  uint32_t attempt;
  uint32_t max_attempts;
} wire_cst_EquipmentEvent_HeartbeatReconnecting;

typedef struct wire_cst_EquipmentEvent_HeartbeatReconnected {
  struct wire_cst_list_prim_u_8_strict *device_type;
  struct wire_cst_list_prim_u_8_strict *device_id;
  uint32_t after_attempts;
} wire_cst_EquipmentEvent_HeartbeatReconnected;

typedef struct wire_cst_EquipmentEvent_DeviceDiscovered {
  struct wire_cst_list_prim_u_8_strict *device_class;
  struct wire_cst_list_prim_u_8_strict *driver;
  struct wire_cst_list_prim_u_8_strict *id;
  struct wire_cst_list_prim_u_8_strict *name;
  struct wire_cst_list_prim_u_8_strict *display_name;
  struct wire_cst_list_prim_u_8_strict *unique_id;
} wire_cst_EquipmentEvent_DeviceDiscovered;

typedef struct wire_cst_EquipmentEvent_DeviceLost {
  struct wire_cst_list_prim_u_8_strict *device_class;
  struct wire_cst_list_prim_u_8_strict *driver;
  struct wire_cst_list_prim_u_8_strict *id;
} wire_cst_EquipmentEvent_DeviceLost;

typedef union EquipmentEventKind {
  struct wire_cst_EquipmentEvent_Connecting Connecting;
  struct wire_cst_EquipmentEvent_Connected Connected;
  struct wire_cst_EquipmentEvent_Disconnected Disconnected;
  struct wire_cst_EquipmentEvent_PropertyChanged PropertyChanged;
  struct wire_cst_EquipmentEvent_Error Error;
  struct wire_cst_EquipmentEvent_MountSlewStarted MountSlewStarted;
  struct wire_cst_EquipmentEvent_MountSlewCompleted MountSlewCompleted;
  struct wire_cst_EquipmentEvent_FocuserMoveStarted FocuserMoveStarted;
  struct wire_cst_EquipmentEvent_FocuserMoveCompleted FocuserMoveCompleted;
  struct wire_cst_EquipmentEvent_FocuserTemperatureChanged FocuserTemperatureChanged;
  struct wire_cst_EquipmentEvent_FilterChanging FilterChanging;
  struct wire_cst_EquipmentEvent_FilterChanged FilterChanged;
  struct wire_cst_EquipmentEvent_RotatorMoveStarted RotatorMoveStarted;
  struct wire_cst_EquipmentEvent_RotatorMoveCompleted RotatorMoveCompleted;
  struct wire_cst_EquipmentEvent_CameraCoolingStarted CameraCoolingStarted;
  struct wire_cst_EquipmentEvent_CameraCoolingReached CameraCoolingReached;
  struct wire_cst_EquipmentEvent_HeartbeatStarted HeartbeatStarted;
  struct wire_cst_EquipmentEvent_HeartbeatStopped HeartbeatStopped;
  struct wire_cst_EquipmentEvent_HeartbeatStatusChanged HeartbeatStatusChanged;
  struct wire_cst_EquipmentEvent_HeartbeatReconnecting HeartbeatReconnecting;
  struct wire_cst_EquipmentEvent_HeartbeatReconnected HeartbeatReconnected;
  struct wire_cst_EquipmentEvent_DeviceDiscovered DeviceDiscovered;
  struct wire_cst_EquipmentEvent_DeviceLost DeviceLost;
} EquipmentEventKind;

typedef struct wire_cst_equipment_event {
  int32_t tag;
  union EquipmentEventKind kind;
} wire_cst_equipment_event;

typedef struct wire_cst_list_prim_i_32_strict {
  int32_t *ptr;
  int32_t len;
} wire_cst_list_prim_i_32_strict;

typedef struct wire_cst_filter_wheel_capabilities {
  int32_t position_count;
  int32_t *current_position;
  struct wire_cst_list_String *filter_names;
  struct wire_cst_list_prim_i_32_strict *focus_offsets;
  bool is_moving;
  bool can_set_filter_names;
  bool can_set_focus_offsets;
} wire_cst_filter_wheel_capabilities;

typedef struct wire_cst_focuser_capabilities {
  int32_t max_position;
  int32_t max_increment;
  double *step_size;
  bool absolute;
  bool temp_comp_available;
  bool temp_comp;
  double *temperature;
  bool is_moving;
  int32_t *position;
  bool can_halt;
  bool can_reverse;
  bool *reverse;
} wire_cst_focuser_capabilities;

typedef struct wire_cst_frame_capture_metadata {
  int32_t *gain;
  int32_t *offset;
  double *sensor_temp_c;
  double *cooler_power_percent;
  double *mount_ra_hours;
  double *mount_dec_degrees;
  double *mount_altitude_deg;
  double *mount_azimuth_deg;
  struct wire_cst_list_prim_u_8_strict *pier_side;
  int32_t *focuser_position;
  double *focuser_temperature_c;
  double *rotator_angle_deg;
  double exposure_secs;
  uint32_t bin_x;
  uint32_t bin_y;
  struct wire_cst_list_prim_u_8_strict *frame_type;
  struct wire_cst_list_prim_u_8_strict *target_id;
} wire_cst_frame_capture_metadata;

typedef struct wire_cst_GuidingEvent_Settled {
  double rms;
} wire_cst_GuidingEvent_Settled;

typedef struct wire_cst_GuidingEvent_DitherStarted {
  double pixels;
} wire_cst_GuidingEvent_DitherStarted;

typedef struct wire_cst_GuidingEvent_Correction {
  double ra;
  double dec;
  double ra_raw;
  double dec_raw;
} wire_cst_GuidingEvent_Correction;

typedef struct wire_cst_GuidingEvent_StarSelected {
  double x;
  double y;
} wire_cst_GuidingEvent_StarSelected;

typedef struct wire_cst_GuidingEvent_AppState {
  struct wire_cst_list_prim_u_8_strict *state;
} wire_cst_GuidingEvent_AppState;

typedef struct wire_cst_GuidingEvent_GuideStats {
  double snr;
  double star_mass;
} wire_cst_GuidingEvent_GuideStats;

typedef union GuidingEventKind {
  struct wire_cst_GuidingEvent_Settled Settled;
  struct wire_cst_GuidingEvent_DitherStarted DitherStarted;
  struct wire_cst_GuidingEvent_Correction Correction;
  struct wire_cst_GuidingEvent_StarSelected StarSelected;
  struct wire_cst_GuidingEvent_AppState AppState;
  struct wire_cst_GuidingEvent_GuideStats GuideStats;
} GuidingEventKind;

typedef struct wire_cst_guiding_event {
  int32_t tag;
  union GuidingEventKind kind;
} wire_cst_guiding_event;

typedef struct wire_cst_ImagingEvent_ExposureStarted {
  double duration_secs;
  int32_t frame_type;
} wire_cst_ImagingEvent_ExposureStarted;

typedef struct wire_cst_ImagingEvent_ExposureStartedWithFrame {
  double duration_secs;
  int32_t frame_type;
  uint32_t frame_number;
  uint32_t *total_frames;
} wire_cst_ImagingEvent_ExposureStartedWithFrame;

typedef struct wire_cst_ImagingEvent_ExposureProgress {
  double progress;
  double remaining_secs;
} wire_cst_ImagingEvent_ExposureProgress;

typedef struct wire_cst_ImagingEvent_ExposureCompleted {
  struct wire_cst_list_prim_u_8_strict *file_path;
  double hfr;
  uint32_t stars_detected;
} wire_cst_ImagingEvent_ExposureCompleted;

typedef struct wire_cst_ImagingEvent_ExposureCompletedWithFrame {
  uint32_t frame_number;
  uint32_t *total_frames;
  double hfr;
  uint32_t stars_detected;
} wire_cst_ImagingEvent_ExposureCompletedWithFrame;

typedef struct wire_cst_ImagingEvent_ExposureFailed {
  struct wire_cst_list_prim_u_8_strict *error;
} wire_cst_ImagingEvent_ExposureFailed;

typedef struct wire_cst_ImagingEvent_ImageReady {
  uint32_t width;
  uint32_t height;
} wire_cst_ImagingEvent_ImageReady;

typedef struct wire_cst_ImagingEvent_ImageSaved {
  struct wire_cst_list_prim_u_8_strict *file_path;
} wire_cst_ImagingEvent_ImageSaved;

typedef struct wire_cst_ImagingEvent_IntegrationProgress {
  struct wire_cst_list_prim_u_8_strict *phase;
  float fraction;
  uint32_t *frames_done;
  uint32_t *frames_total;
} wire_cst_ImagingEvent_IntegrationProgress;

typedef struct wire_cst_ImagingEvent_TemperatureChanged {
  double temp_celsius;
  double cooler_power;
} wire_cst_ImagingEvent_TemperatureChanged;

typedef struct wire_cst_ImagingEvent_ExposureComplete {
  bool success;
} wire_cst_ImagingEvent_ExposureComplete;

typedef struct wire_cst_ImagingEvent_ExposureFailedOld {
  struct wire_cst_list_prim_u_8_strict *reason;
} wire_cst_ImagingEvent_ExposureFailedOld;

typedef union ImagingEventKind {
  struct wire_cst_ImagingEvent_ExposureStarted ExposureStarted;
  struct wire_cst_ImagingEvent_ExposureStartedWithFrame ExposureStartedWithFrame;
  struct wire_cst_ImagingEvent_ExposureProgress ExposureProgress;
  struct wire_cst_ImagingEvent_ExposureCompleted ExposureCompleted;
  struct wire_cst_ImagingEvent_ExposureCompletedWithFrame ExposureCompletedWithFrame;
  struct wire_cst_ImagingEvent_ExposureFailed ExposureFailed;
  struct wire_cst_ImagingEvent_ImageReady ImageReady;
  struct wire_cst_ImagingEvent_ImageSaved ImageSaved;
  struct wire_cst_ImagingEvent_IntegrationProgress IntegrationProgress;
  struct wire_cst_ImagingEvent_TemperatureChanged TemperatureChanged;
  struct wire_cst_ImagingEvent_ExposureComplete ExposureComplete;
  struct wire_cst_ImagingEvent_ExposureFailedOld ExposureFailedOld;
} ImagingEventKind;

typedef struct wire_cst_imaging_event {
  int32_t tag;
  union ImagingEventKind kind;
} wire_cst_imaging_event;

typedef struct wire_cst_live_stacking_broadcast_snapshot {
  struct wire_cst_list_prim_u_8_strict *node_id;
  struct wire_cst_list_prim_u_8_strict *mode;
  struct wire_cst_list_prim_u_8_strict *stack_method;
  bool broadcast_enabled;
  uint16_t broadcast_port;
  struct wire_cst_list_prim_u_8_strict *broadcast_path;
  struct wire_cst_list_prim_u_8_strict *auth_token;
  struct wire_cst_list_prim_u_8_strict *watermark_template;
  uint32_t thumbnail_width;
  uint32_t thumbnail_height;
  uint32_t max_frames_to_stack;
  int64_t activated_at_unix_millis;
} wire_cst_live_stacking_broadcast_snapshot;

typedef struct wire_cst_list_tracking_rate {
  int32_t *ptr;
  int32_t len;
} wire_cst_list_tracking_rate;

typedef struct wire_cst_mount_capabilities {
  bool can_slew;
  bool can_slew_async;
  bool can_sync;
  bool can_park;
  bool can_unpark;
  bool can_set_park;
  bool can_pulse_guide;
  bool can_get_side_of_pier;
  bool can_set_side_of_pier;
  bool can_set_tracking;
  bool can_set_tracking_rate;
  struct wire_cst_list_tracking_rate *supported_tracking_rates;
  bool is_equatorial;
  bool supports_alt_az;
  bool can_get_pointing_state;
  bool can_find_home;
  bool *tracking;
  int32_t *tracking_rate;
  bool can_abort_slew;
  double *max_slew_rate;
  bool can_move_axis;
  uint32_t axis_count;
  double *min_pulse_guide_ms;
  double *max_pulse_guide_ms;
} wire_cst_mount_capabilities;

typedef struct wire_cst_polar_alignment_event {
  double azimuth_error;
  double altitude_error;
  double total_error;
  double current_ra;
  double current_dec;
  double target_ra;
  double target_dec;
} wire_cst_polar_alignment_event;

typedef struct wire_cst_polar_alignment_image_event {
  struct wire_cst_list_prim_u_8_strict *image_data;
  uint32_t width;
  uint32_t height;
  double *solved_ra;
  double *solved_dec;
  int32_t point;
  struct wire_cst_list_prim_u_8_strict *phase;
} wire_cst_polar_alignment_image_event;

typedef struct wire_cst_polar_alignment_status {
  struct wire_cst_list_prim_u_8_strict *status;
  struct wire_cst_list_prim_u_8_strict *phase;
  int32_t point;
} wire_cst_polar_alignment_status;

typedef struct wire_cst_record_f_64_f_64 {
  double field0;
  double field1;
} wire_cst_record_f_64_f_64;

typedef struct wire_cst_rotator_capabilities {
  bool can_reverse;
  bool reverse;
  double *step_size;
  bool is_moving;
  double *mechanical_position;
  double *position;
  bool can_move_absolute;
  bool can_halt;
  bool can_sync;
  double *min_angle_deg;
  double *max_angle_deg;
} wire_cst_rotator_capabilities;

typedef struct wire_cst_SafetyEvent_WeatherUnsafe {
  struct wire_cst_list_prim_u_8_strict *reason;
} wire_cst_SafetyEvent_WeatherUnsafe;

typedef struct wire_cst_SafetyEvent_EmergencyStop {
  struct wire_cst_list_prim_u_8_strict *reason;
} wire_cst_SafetyEvent_EmergencyStop;

typedef struct wire_cst_SafetyEvent_ParkInitiated {
  struct wire_cst_list_prim_u_8_strict *reason;
} wire_cst_SafetyEvent_ParkInitiated;

typedef union SafetyEventKind {
  struct wire_cst_SafetyEvent_WeatherUnsafe WeatherUnsafe;
  struct wire_cst_SafetyEvent_EmergencyStop EmergencyStop;
  struct wire_cst_SafetyEvent_ParkInitiated ParkInitiated;
} SafetyEventKind;

typedef struct wire_cst_safety_event {
  int32_t tag;
  union SafetyEventKind kind;
} wire_cst_safety_event;

typedef struct wire_cst_safety_monitor_capabilities {
  bool is_safe;
  struct wire_cst_list_prim_u_8_strict *safety_description;
} wire_cst_safety_monitor_capabilities;

typedef struct wire_cst_SequencerEvent_Started {
  struct wire_cst_list_prim_u_8_strict *sequence_name;
} wire_cst_SequencerEvent_Started;

typedef struct wire_cst_SequencerEvent_Stopped {
  int64_t *sequence_run_id;
} wire_cst_SequencerEvent_Stopped;

typedef struct wire_cst_SequencerEvent_Failed {
  struct wire_cst_list_prim_u_8_strict *error;
} wire_cst_SequencerEvent_Failed;

typedef struct wire_cst_SequencerEvent_NodeStarted {
  struct wire_cst_list_prim_u_8_strict *node_id;
  struct wire_cst_list_prim_u_8_strict *node_type;
} wire_cst_SequencerEvent_NodeStarted;

typedef struct wire_cst_SequencerEvent_NodeCompleted {
  struct wire_cst_list_prim_u_8_strict *node_id;
  struct wire_cst_list_prim_u_8_strict *status;
} wire_cst_SequencerEvent_NodeCompleted;

typedef struct wire_cst_SequencerEvent_Progress {
  uint32_t current;
  uint32_t total;
} wire_cst_SequencerEvent_Progress;

typedef struct wire_cst_SequencerEvent_TargetChanged {
  struct wire_cst_list_prim_u_8_strict *target_name;
  double *ra;
  double *dec;
} wire_cst_SequencerEvent_TargetChanged;

typedef struct wire_cst_SequencerEvent_TargetCompleted {
  struct wire_cst_list_prim_u_8_strict *target_name;
} wire_cst_SequencerEvent_TargetCompleted;

typedef struct wire_cst_SequencerEvent_ExposureStarted {
  uint32_t frame;
  uint32_t total;
  struct wire_cst_list_prim_u_8_strict *filter;
  double duration_secs;
} wire_cst_SequencerEvent_ExposureStarted;

typedef struct wire_cst_SequencerEvent_ExposureCompleted {
  uint32_t frame;
  uint32_t total;
  double duration_secs;
} wire_cst_SequencerEvent_ExposureCompleted;

typedef struct wire_cst_SequencerEvent_Error {
  struct wire_cst_list_prim_u_8_strict *message;
} wire_cst_SequencerEvent_Error;

typedef struct wire_cst_SequencerEvent_MeridianFlipOutcome {
  struct wire_cst_list_prim_u_8_strict *outcome;
  struct wire_cst_list_prim_u_8_strict *target_name;
  struct wire_cst_list_prim_u_8_strict *new_pier_side;
  double duration_secs;
  uint32_t attempts;
  struct wire_cst_list_String *failed_steps;
  struct wire_cst_list_prim_u_8_strict *error;
  struct wire_cst_list_prim_u_8_strict *action_taken;
} wire_cst_SequencerEvent_MeridianFlipOutcome;

typedef struct wire_cst_SequencerEvent_TriggerFired {
  struct wire_cst_list_prim_u_8_strict *trigger_id;
  struct wire_cst_list_prim_u_8_strict *trigger_name;
  struct wire_cst_list_prim_u_8_strict *action;
} wire_cst_SequencerEvent_TriggerFired;

typedef struct wire_cst_SequencerEvent_InstructionProgress {
  struct wire_cst_list_prim_u_8_strict *node_id;
  struct wire_cst_list_prim_u_8_strict *instruction;
  double progress_percent;
  struct wire_cst_list_prim_u_8_strict *detail;
} wire_cst_SequencerEvent_InstructionProgress;

typedef struct wire_cst_SequencerEvent_InstructionProgressStructured {
  struct wire_cst_list_prim_u_8_strict *node_id;
  struct wire_cst_list_prim_u_8_strict *instruction;
  double progress_percent;
  struct wire_cst_list_prim_u_8_strict *detail_kind;
  struct wire_cst_list_prim_u_8_strict *detail_json;
} wire_cst_SequencerEvent_InstructionProgressStructured;

typedef struct wire_cst_SequencerEvent_DepthGoalCompleted {
  struct wire_cst_list_prim_u_8_strict *node_id;
  struct wire_cst_list_prim_u_8_strict *filter_name;
  struct wire_cst_list_prim_u_8_strict *goal_id;
  uint64_t revision;
  uint32_t evidence_frames;
  uint32_t confirmation_frames;
  double score;
  double threshold;
} wire_cst_SequencerEvent_DepthGoalCompleted;

typedef struct wire_cst_SequencerEvent_FrameAccepted {
  struct wire_cst_list_prim_u_8_strict *node_id;
  uint32_t frame;
  uint32_t total;
  double *hfr;
  double *eccentricity;
  uint32_t *star_count;
  uint32_t accepted_total;
  uint32_t rejected_total;
  struct wire_cst_list_prim_u_8_strict *save_path;
  struct wire_cst_frame_capture_metadata *capture;
} wire_cst_SequencerEvent_FrameAccepted;

typedef struct wire_cst_SequencerEvent_FrameRejected {
  struct wire_cst_list_prim_u_8_strict *node_id;
  uint32_t frame;
  uint32_t total;
  struct wire_cst_list_prim_u_8_strict *reason;
  double *hfr;
  double *eccentricity;
  uint32_t *star_count;
  struct wire_cst_list_prim_u_8_strict *reject_path;
  uint32_t consecutive_rejects;
  uint32_t accepted_total;
  uint32_t rejected_total;
  struct wire_cst_list_prim_u_8_strict *likely_cause_label;
  struct wire_cst_list_String *evidence;
  double *sky_brightness_at_capture;
  double *cloud_cover_at_capture;
  double *wind_at_capture;
  double *guide_rms_at_capture;
  double *sensor_temp_at_capture;
  struct wire_cst_frame_capture_metadata *capture;
} wire_cst_SequencerEvent_FrameRejected;

typedef struct wire_cst_scheduler_score_entry {
  struct wire_cst_list_prim_u_8_strict *target_id;
  struct wire_cst_list_prim_u_8_strict *target_name;
  double total_score;
  bool runnable;
  struct wire_cst_list_prim_u_8_strict *reason;
} wire_cst_scheduler_score_entry;

typedef struct wire_cst_list_scheduler_score_entry {
  struct wire_cst_scheduler_score_entry *ptr;
  int32_t len;
} wire_cst_list_scheduler_score_entry;

typedef struct wire_cst_SequencerEvent_SchedulerDecision {
  struct wire_cst_list_prim_u_8_strict *node_id;
  uint32_t decision_counter;
  struct wire_cst_list_prim_u_8_strict *picked_target_id;
  struct wire_cst_list_prim_u_8_strict *picked_target_name;
  double *picked_score;
  struct wire_cst_list_scheduler_score_entry *scores;
} wire_cst_SequencerEvent_SchedulerDecision;

typedef struct wire_cst_SequencerEvent_IntegrationBudget {
  struct wire_cst_list_prim_u_8_strict *target_id;
  struct wire_cst_list_prim_u_8_strict *filter;
  double completed_secs;
  double budget_secs;
  double fraction;
  bool budget_met;
} wire_cst_SequencerEvent_IntegrationBudget;

typedef struct wire_cst_SequencerEvent_ExposureAdjusted {
  struct wire_cst_list_prim_u_8_strict *node_id;
  double adapted_secs;
  double nominal_secs;
  double *sky_brightness_mag;
  struct wire_cst_list_prim_u_8_strict *filter;
  struct wire_cst_list_prim_u_8_strict *reason;
} wire_cst_SequencerEvent_ExposureAdjusted;

typedef struct wire_cst_SequencerEvent_PhotometryFrame {
  struct wire_cst_list_prim_u_8_strict *node_id;
  struct wire_cst_list_prim_u_8_strict *target_designation;
  struct wire_cst_list_String *reference_stars;
  uint32_t frame;
  uint32_t total;
  struct wire_cst_list_prim_u_8_strict *filter;
  double exposure_secs;
  double *airmass;
  double *fwhm_arcsec;
  double *snr;
  double mjd_obs;
  double frame_start_unix;
  bool accepted;
  struct wire_cst_list_prim_u_8_strict *reject_reason;
  bool reduce_live;
  bool apply_differential;
} wire_cst_SequencerEvent_PhotometryFrame;

typedef struct wire_cst_SequencerEvent_PhotometryCadenceBroken {
  struct wire_cst_list_prim_u_8_strict *node_id;
  uint32_t frame;
  uint32_t total;
  double gap_secs;
  double max_gap_secs;
  uint32_t cadence_breaks;
} wire_cst_SequencerEvent_PhotometryCadenceBroken;

typedef struct wire_cst_SequencerEvent_PhotometrySummary {
  struct wire_cst_list_prim_u_8_strict *node_id;
  struct wire_cst_list_prim_u_8_strict *target_designation;
  struct wire_cst_list_prim_u_8_strict *filter;
  uint32_t frames_captured;
  uint32_t cadence_breaks;
  struct wire_cst_list_prim_u_8_strict *last_reject_reason;
} wire_cst_SequencerEvent_PhotometrySummary;

typedef struct wire_cst_SequencerEvent_RecoveryStarted {
  struct wire_cst_list_prim_u_8_strict *started_at_iso;
  struct wire_cst_list_prim_u_8_strict *cause_kind;
  struct wire_cst_list_prim_u_8_strict *cause_custom_label;
  struct wire_cst_list_prim_u_8_strict *last_attempt_at_iso;
  uint32_t attempt_count;
  uint32_t max_attempts;
  double retry_interval_secs;
  double max_duration_secs;
  struct wire_cst_list_prim_u_8_strict *phase;
  struct wire_cst_list_prim_u_8_strict *last_error;
} wire_cst_SequencerEvent_RecoveryStarted;

typedef struct wire_cst_SequencerEvent_RecoveryProgress {
  struct wire_cst_list_prim_u_8_strict *started_at_iso;
  struct wire_cst_list_prim_u_8_strict *cause_kind;
  struct wire_cst_list_prim_u_8_strict *cause_custom_label;
  struct wire_cst_list_prim_u_8_strict *last_attempt_at_iso;
  uint32_t attempt_count;
  uint32_t max_attempts;
  double retry_interval_secs;
  double max_duration_secs;
  struct wire_cst_list_prim_u_8_strict *phase;
  struct wire_cst_list_prim_u_8_strict *last_error;
} wire_cst_SequencerEvent_RecoveryProgress;

typedef struct wire_cst_SequencerEvent_RecoveryCompleted {
  struct wire_cst_list_prim_u_8_strict *started_at_iso;
  struct wire_cst_list_prim_u_8_strict *cause_kind;
  struct wire_cst_list_prim_u_8_strict *cause_custom_label;
  struct wire_cst_list_prim_u_8_strict *last_attempt_at_iso;
  uint32_t attempt_count;
  uint32_t max_attempts;
  double retry_interval_secs;
  double max_duration_secs;
  struct wire_cst_list_prim_u_8_strict *phase;
  struct wire_cst_list_prim_u_8_strict *last_error;
} wire_cst_SequencerEvent_RecoveryCompleted;

typedef struct wire_cst_SequencerEvent_RecoveryGaveUp {
  struct wire_cst_list_prim_u_8_strict *started_at_iso;
  struct wire_cst_list_prim_u_8_strict *cause_kind;
  struct wire_cst_list_prim_u_8_strict *cause_custom_label;
  struct wire_cst_list_prim_u_8_strict *last_attempt_at_iso;
  uint32_t attempt_count;
  uint32_t max_attempts;
  double retry_interval_secs;
  double max_duration_secs;
  struct wire_cst_list_prim_u_8_strict *phase;
  struct wire_cst_list_prim_u_8_strict *last_error;
  bool aborted_by_user;
} wire_cst_SequencerEvent_RecoveryGaveUp;

typedef struct wire_cst_SequencerEvent_PluginNodeRequested {
  struct wire_cst_list_prim_u_8_strict *node_id;
  struct wire_cst_list_prim_u_8_strict *plugin_id;
  struct wire_cst_list_prim_u_8_strict *node_type_id;
  struct wire_cst_list_prim_u_8_strict *config_json;
  struct wire_cst_list_prim_u_8_strict *display_name;
  uint32_t timeout_secs;
} wire_cst_SequencerEvent_PluginNodeRequested;

typedef struct wire_cst_SequencerEvent_PluginNodeProgress {
  struct wire_cst_list_prim_u_8_strict *node_id;
  struct wire_cst_list_prim_u_8_strict *plugin_id;
  struct wire_cst_list_prim_u_8_strict *node_type_id;
  struct wire_cst_list_prim_u_8_strict *detail_json;
} wire_cst_SequencerEvent_PluginNodeProgress;

typedef struct wire_cst_SequencerEvent_DecisionLogged {
  struct wire_cst_list_prim_u_8_strict *timestamp_iso;
  struct wire_cst_list_prim_u_8_strict *category;
  struct wire_cst_list_prim_u_8_strict *summary;
  struct wire_cst_list_prim_u_8_strict *details_json;
  struct wire_cst_list_prim_u_8_strict *node_id;
  int64_t *sequence_run_id;
} wire_cst_SequencerEvent_DecisionLogged;

typedef union SequencerEventKind {
  struct wire_cst_SequencerEvent_Started Started;
  struct wire_cst_SequencerEvent_Stopped Stopped;
  struct wire_cst_SequencerEvent_Failed Failed;
  struct wire_cst_SequencerEvent_NodeStarted NodeStarted;
  struct wire_cst_SequencerEvent_NodeCompleted NodeCompleted;
  struct wire_cst_SequencerEvent_Progress Progress;
  struct wire_cst_SequencerEvent_TargetChanged TargetChanged;
  struct wire_cst_SequencerEvent_TargetCompleted TargetCompleted;
  struct wire_cst_SequencerEvent_ExposureStarted ExposureStarted;
  struct wire_cst_SequencerEvent_ExposureCompleted ExposureCompleted;
  struct wire_cst_SequencerEvent_Error Error;
  struct wire_cst_SequencerEvent_MeridianFlipOutcome MeridianFlipOutcome;
  struct wire_cst_SequencerEvent_TriggerFired TriggerFired;
  struct wire_cst_SequencerEvent_InstructionProgress InstructionProgress;
  struct wire_cst_SequencerEvent_InstructionProgressStructured InstructionProgressStructured;
  struct wire_cst_SequencerEvent_DepthGoalCompleted DepthGoalCompleted;
  struct wire_cst_SequencerEvent_FrameAccepted FrameAccepted;
  struct wire_cst_SequencerEvent_FrameRejected FrameRejected;
  struct wire_cst_SequencerEvent_SchedulerDecision SchedulerDecision;
  struct wire_cst_SequencerEvent_IntegrationBudget IntegrationBudget;
  struct wire_cst_SequencerEvent_ExposureAdjusted ExposureAdjusted;
  struct wire_cst_SequencerEvent_PhotometryFrame PhotometryFrame;
  struct wire_cst_SequencerEvent_PhotometryCadenceBroken PhotometryCadenceBroken;
  struct wire_cst_SequencerEvent_PhotometrySummary PhotometrySummary;
  struct wire_cst_SequencerEvent_RecoveryStarted RecoveryStarted;
  struct wire_cst_SequencerEvent_RecoveryProgress RecoveryProgress;
  struct wire_cst_SequencerEvent_RecoveryCompleted RecoveryCompleted;
  struct wire_cst_SequencerEvent_RecoveryGaveUp RecoveryGaveUp;
  struct wire_cst_SequencerEvent_PluginNodeRequested PluginNodeRequested;
  struct wire_cst_SequencerEvent_PluginNodeProgress PluginNodeProgress;
  struct wire_cst_SequencerEvent_DecisionLogged DecisionLogged;
} SequencerEventKind;

typedef struct wire_cst_sequencer_event {
  int32_t tag;
  union SequencerEventKind kind;
} wire_cst_sequencer_event;

typedef struct wire_cst_switch_info {
  int32_t index;
  struct wire_cst_list_prim_u_8_strict *name;
  struct wire_cst_list_prim_u_8_strict *description;
  bool is_boolean;
  double min_value;
  double max_value;
  double step;
  bool can_write;
  double value;
} wire_cst_switch_info;

typedef struct wire_cst_list_switch_info {
  struct wire_cst_switch_info *ptr;
  int32_t len;
} wire_cst_list_switch_info;

typedef struct wire_cst_switch_capabilities {
  int32_t switch_count;
  struct wire_cst_list_switch_info *switches;
} wire_cst_switch_capabilities;

typedef struct wire_cst_SystemEvent_Error {
  struct wire_cst_list_prim_u_8_strict *message;
} wire_cst_SystemEvent_Error;

typedef struct wire_cst_SystemEvent_DiskSpaceLow {
  double available_gb;
} wire_cst_SystemEvent_DiskSpaceLow;

typedef struct wire_cst_SystemEvent_Notification {
  struct wire_cst_list_prim_u_8_strict *title;
  struct wire_cst_list_prim_u_8_strict *message;
  struct wire_cst_list_prim_u_8_strict *level;
  struct wire_cst_list_String *explicit_transports;
} wire_cst_SystemEvent_Notification;

typedef struct wire_cst_SystemEvent_EventsDropped {
  uint64_t dropped_count;
  uint64_t total_dropped;
} wire_cst_SystemEvent_EventsDropped;

typedef union SystemEventKind {
  struct wire_cst_SystemEvent_Error Error;
  struct wire_cst_SystemEvent_DiskSpaceLow DiskSpaceLow;
  struct wire_cst_SystemEvent_Notification Notification;
  struct wire_cst_SystemEvent_EventsDropped EventsDropped;
} SystemEventKind;

typedef struct wire_cst_system_event {
  int32_t tag;
  union SystemEventKind kind;
} wire_cst_system_event;

typedef struct wire_cst_weather_capabilities {
  bool has_cloud_cover;
  bool has_dew_point;
  bool has_humidity;
  bool has_pressure;
  bool has_rain_rate;
  bool has_sky_brightness;
  bool has_sky_quality;
  bool has_sky_temperature;
  bool has_seeing;
  bool has_temperature;
  bool has_wind_direction;
  bool has_wind_gust;
  bool has_wind_speed;
  double *average_period;
} wire_cst_weather_capabilities;

typedef struct wire_cst_api_depth_curve_point {
  uint32_t frames;
  double score;
  double conservative_score;
  bool projected;
} wire_cst_api_depth_curve_point;

typedef struct wire_cst_list_api_depth_curve_point {
  struct wire_cst_api_depth_curve_point *ptr;
  int32_t len;
} wire_cst_list_api_depth_curve_point;

typedef struct wire_cst_api_depth_goal {
  struct wire_cst_list_prim_u_8_strict *id;
  uint64_t revision;
  struct wire_cst_api_depth_goal_definition definition;
  int64_t selected_at_ms;
  uint32_t evidence_frames;
  uint64_t evidence_revision;
  bool analysis_current;
  struct wire_cst_api_depth_report *report;
  uint32_t candidate_frames;
  struct wire_cst_list_prim_u_8_strict *last_issue;
  uint32_t archived_revisions;
  uint32_t estimator_version;
} wire_cst_api_depth_goal;

typedef struct wire_cst_list_api_depth_goal {
  struct wire_cst_api_depth_goal *ptr;
  int32_t len;
} wire_cst_list_api_depth_goal;

typedef struct wire_cst_detected_star_info {
  double x;
  double y;
  double flux;
  double hfr;
  double fwhm;
  double peak;
  double background;
  double snr;
  double eccentricity;
  double sharpness;
} wire_cst_detected_star_info;

typedef struct wire_cst_list_detected_star_info {
  struct wire_cst_detected_star_info *ptr;
  int32_t len;
} wire_cst_list_detected_star_info;

typedef struct wire_cst_device_info {
  struct wire_cst_list_prim_u_8_strict *id;
  struct wire_cst_list_prim_u_8_strict *name;
  int32_t device_type;
  int32_t driver_type;
  struct wire_cst_list_prim_u_8_strict *description;
  struct wire_cst_list_prim_u_8_strict *driver_version;
  struct wire_cst_list_prim_u_8_strict *serial_number;
  struct wire_cst_list_prim_u_8_strict *unique_id;
  struct wire_cst_list_prim_u_8_strict *display_name;
} wire_cst_device_info;

typedef struct wire_cst_list_device_info {
  struct wire_cst_device_info *ptr;
  int32_t len;
} wire_cst_list_device_info;

typedef struct wire_cst_list_equipment_profile {
  struct wire_cst_equipment_profile *ptr;
  int32_t len;
} wire_cst_list_equipment_profile;

typedef struct wire_cst_focus_data_point {
  int32_t position;
  double hfr;
  double *fwhm;
  uint32_t star_count;
} wire_cst_focus_data_point;

typedef struct wire_cst_list_focus_data_point {
  struct wire_cst_focus_data_point *ptr;
  int32_t len;
} wire_cst_list_focus_data_point;

typedef struct wire_cst_focus_data_point_api {
  int32_t position;
  double hfr;
  double *fwhm;
  uint32_t star_count;
} wire_cst_focus_data_point_api;

typedef struct wire_cst_list_focus_data_point_api {
  struct wire_cst_focus_data_point_api *ptr;
  int32_t len;
} wire_cst_list_focus_data_point_api;

typedef struct wire_cst_mosaic_panel_result {
  double ra_hours;
  double dec_degrees;
  uint32_t panel_index;
  uint32_t row;
  uint32_t col;
} wire_cst_mosaic_panel_result;

typedef struct wire_cst_list_mosaic_panel_result {
  struct wire_cst_mosaic_panel_result *ptr;
  int32_t len;
} wire_cst_list_mosaic_panel_result;

typedef struct wire_cst_phd_2_algo_param {
  struct wire_cst_list_prim_u_8_strict *name;
  double value;
} wire_cst_phd_2_algo_param;

typedef struct wire_cst_list_phd_2_algo_param {
  struct wire_cst_phd_2_algo_param *ptr;
  int32_t len;
} wire_cst_list_phd_2_algo_param;

typedef struct wire_cst_list_prim_f_32_strict {
  float *ptr;
  int32_t len;
} wire_cst_list_prim_f_32_strict;

typedef struct wire_cst_list_prim_f_64_strict {
  double *ptr;
  int32_t len;
} wire_cst_list_prim_f_64_strict;

typedef struct wire_cst_list_prim_u_32_strict {
  uint32_t *ptr;
  int32_t len;
} wire_cst_list_prim_u_32_strict;

typedef struct wire_cst_quality_tile_metric_api {
  struct wire_cst_list_prim_u_8_strict *layer_type;
  uint32_t tile_row;
  uint32_t tile_col;
  uint32_t sample_count;
  double value;
  double p05;
  double p50;
  double p95;
  double aux_value;
} wire_cst_quality_tile_metric_api;

typedef struct wire_cst_list_quality_tile_metric_api {
  struct wire_cst_quality_tile_metric_api *ptr;
  int32_t len;
} wire_cst_list_quality_tile_metric_api;

typedef struct wire_cst_quirk_info {
  struct wire_cst_list_prim_u_8_strict *category;
  struct wire_cst_list_prim_u_8_strict *description;
} wire_cst_quirk_info;

typedef struct wire_cst_list_quirk_info {
  struct wire_cst_quirk_info *ptr;
  int32_t len;
} wire_cst_list_quirk_info;

typedef struct wire_cst_FieldAvailability_Error {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_FieldAvailability_Error;

typedef union FieldAvailabilityKind {
  struct wire_cst_FieldAvailability_Error Error;
} FieldAvailabilityKind;

typedef struct wire_cst_field_availability {
  int32_t tag;
  union FieldAvailabilityKind kind;
} wire_cst_field_availability;

typedef struct wire_cst_record_string_field_availability {
  struct wire_cst_list_prim_u_8_strict *field0;
  struct wire_cst_field_availability field1;
} wire_cst_record_string_field_availability;

typedef struct wire_cst_list_record_string_field_availability {
  struct wire_cst_record_string_field_availability *ptr;
  int32_t len;
} wire_cst_list_record_string_field_availability;

typedef struct wire_cst_star_crop_api {
  struct wire_cst_list_prim_u_8_strict *pixels_base64;
  uint32_t width;
  uint32_t height;
  double hfr;
  double snr;
} wire_cst_star_crop_api;

typedef struct wire_cst_list_star_crop_api {
  struct wire_cst_star_crop_api *ptr;
  int32_t len;
} wire_cst_list_star_crop_api;

typedef struct wire_cst_api_depth_floor_suggestion {
  double floor_adu;
  double dark_noise_adu;
  double flat_relative_noise;
  double sky_adu;
  double aperture_pixels;
  struct wire_cst_list_prim_u_8_strict *source;
} wire_cst_api_depth_floor_suggestion;

typedef struct wire_cst_api_depth_ingest_outcome {
  struct wire_cst_list_prim_u_8_strict *outcome;
  struct wire_cst_list_prim_u_8_strict *state;
  struct wire_cst_list_prim_u_8_strict *reason;
} wire_cst_api_depth_ingest_outcome;

typedef struct wire_cst_api_depth_lock_status {
  bool available;
  uint32_t goals;
  uint32_t queue_capacity;
  uint64_t queued;
  uint64_t processed;
  uint64_t dropped;
  uint64_t evidence_added;
  uint64_t evidence_rejected;
  uint64_t last_frame_ms;
  uint64_t max_frame_ms;
} wire_cst_api_depth_lock_status;

typedef struct wire_cst_api_depth_reference_info {
  uint32_t width;
  uint32_t height;
  struct wire_cst_list_prim_u_8_strict *pixel_type;
  bool monochrome;
  struct wire_cst_api_reference_geometry *geometry;
  struct wire_cst_list_prim_u_8_strict *geometry_issue;
  double *pixel_scale_arcsec;
  struct wire_cst_api_acquisition_settings *acquisition;
  struct wire_cst_list_prim_u_8_strict *acquisition_issue;
} wire_cst_api_depth_reference_info;

typedef struct wire_cst_api_live_stacking_master {
  struct wire_cst_list_prim_u_8_strict *file_path;
  uint32_t stacked_frame_count;
  double total_integration_secs;
  struct wire_cst_list_prim_u_8_strict *date_obs;
} wire_cst_api_live_stacking_master;

typedef struct wire_cst_api_live_stacking_stats {
  uint32_t stacked_frame_count;
  uint32_t total_frames_attempted;
  uint32_t rejected_alignment_failures;
  double avg_matched_pairs;
  double avg_alignment_residual;
  uint64_t total_sigma_rejected_pixels;
} wire_cst_api_live_stacking_stats;

typedef struct wire_cst_api_live_stacking_result {
  uint32_t width;
  uint32_t height;
  uint32_t channels;
  struct wire_cst_list_prim_u_16_strict *data;
  struct wire_cst_api_live_stacking_stats stats;
} wire_cst_api_live_stacking_result;

typedef struct wire_cst_api_master_frame_result {
  struct wire_cst_list_prim_u_8_strict *output_path;
  struct wire_cst_list_prim_u_8_strict *kind;
  struct wire_cst_list_prim_u_8_strict *output_type;
  uint32_t frame_count;
  struct wire_cst_list_prim_u_8_strict *method;
  uint32_t width;
  uint32_t height;
  uint32_t channels;
  double input_mean;
  double output_mean;
} wire_cst_api_master_frame_result;

typedef struct wire_cst_autofocus_result_api {
  int32_t best_position;
  double best_hfr;
  struct wire_cst_list_focus_data_point *focus_data;
  struct wire_cst_list_prim_u_8_strict *method;
  double *temperature;
  int64_t timestamp;
  double curve_fit_quality;
  bool backlash_applied;
} wire_cst_autofocus_result_api;

typedef struct wire_cst_builtin_guider_config {
  double exposure_secs;
  int32_t gain;
  int32_t offset;
  int32_t binning;
  uint32_t calibration_ms;
  uint64_t settle_sleep_ms;
  double min_pulse_ms;
  double max_pulse_ms;
} wire_cst_builtin_guider_config;

typedef struct wire_cst_camera_recommended_settings {
  int32_t *unity_gain;
  int32_t *hcg_gain;
  int32_t *default_offset;
  double *recommended_cooling_setpoint_c;
  struct wire_cst_list_prim_u_8_strict *notes;
} wire_cst_camera_recommended_settings;

typedef struct wire_cst_camera_status {
  bool connected;
  int32_t state;
  double *sensor_temp;
  double *cooler_power;
  double *target_temp;
  bool cooler_on;
  int32_t gain;
  int32_t offset;
  int32_t bin_x;
  int32_t bin_y;
  uint32_t sensor_width;
  uint32_t sensor_height;
  double pixel_size_x;
  double pixel_size_y;
  uint32_t max_adu;
  bool can_cool;
  bool can_set_gain;
  bool can_set_offset;
} wire_cst_camera_status;

typedef struct wire_cst_image_stats_result {
  double min;
  double max;
  double mean;
  double median;
  double std_dev;
  double *hfr;
  double *eccentricity;
  double *fwhm;
  uint32_t star_count;
} wire_cst_image_stats_result;

typedef struct wire_cst_captured_image_result {
  uint32_t width;
  uint32_t height;
  struct wire_cst_list_prim_u_8_strict *display_data;
  struct wire_cst_list_prim_u_32_strict *histogram;
  struct wire_cst_image_stats_result stats;
  double exposure_time;
  struct wire_cst_list_prim_u_8_strict *timestamp;
  bool is_color;
} wire_cst_captured_image_result;

typedef struct wire_cst_cover_calibrator_status {
  bool connected;
  int32_t cover_state;
  int32_t calibrator_state;
  int32_t brightness;
  int32_t max_brightness;
} wire_cst_cover_calibrator_status;

typedef struct wire_cst_darkroom_preview {
  uint32_t width;
  uint32_t height;
  bool is_color;
  struct wire_cst_list_prim_u_8_strict *rgba;
  struct wire_cst_list_prim_u_8_strict *report_json;
} wire_cst_darkroom_preview;

typedef struct wire_cst_device_api_version {
  struct wire_cst_list_prim_u_8_strict *device_id;
  int32_t driver_type;
  uint32_t *interface_version;
  struct wire_cst_list_prim_u_8_strict *protocol_version;
  struct wire_cst_list_prim_u_8_strict *driver_version;
  struct wire_cst_list_prim_u_8_strict *driver_info;
  struct wire_cst_list_String *supported_actions;
  int64_t queried_at;
} wire_cst_device_api_version;

typedef struct wire_cst_DeviceCapabilities_Mount {
  struct wire_cst_mount_capabilities *field0;
} wire_cst_DeviceCapabilities_Mount;

typedef struct wire_cst_DeviceCapabilities_Camera {
  struct wire_cst_camera_capabilities *field0;
} wire_cst_DeviceCapabilities_Camera;

typedef struct wire_cst_DeviceCapabilities_Focuser {
  struct wire_cst_focuser_capabilities *field0;
} wire_cst_DeviceCapabilities_Focuser;

typedef struct wire_cst_DeviceCapabilities_FilterWheel {
  struct wire_cst_filter_wheel_capabilities *field0;
} wire_cst_DeviceCapabilities_FilterWheel;

typedef struct wire_cst_DeviceCapabilities_Rotator {
  struct wire_cst_rotator_capabilities *field0;
} wire_cst_DeviceCapabilities_Rotator;

typedef struct wire_cst_DeviceCapabilities_Dome {
  struct wire_cst_dome_capabilities *field0;
} wire_cst_DeviceCapabilities_Dome;

typedef struct wire_cst_DeviceCapabilities_CoverCalibrator {
  struct wire_cst_cover_calibrator_capabilities *field0;
} wire_cst_DeviceCapabilities_CoverCalibrator;

typedef struct wire_cst_DeviceCapabilities_Weather {
  struct wire_cst_weather_capabilities *field0;
} wire_cst_DeviceCapabilities_Weather;

typedef struct wire_cst_DeviceCapabilities_SafetyMonitor {
  struct wire_cst_safety_monitor_capabilities *field0;
} wire_cst_DeviceCapabilities_SafetyMonitor;

typedef struct wire_cst_DeviceCapabilities_Switch {
  struct wire_cst_switch_capabilities *field0;
} wire_cst_DeviceCapabilities_Switch;

typedef union DeviceCapabilitiesKind {
  struct wire_cst_DeviceCapabilities_Mount Mount;
  struct wire_cst_DeviceCapabilities_Camera Camera;
  struct wire_cst_DeviceCapabilities_Focuser Focuser;
  struct wire_cst_DeviceCapabilities_FilterWheel FilterWheel;
  struct wire_cst_DeviceCapabilities_Rotator Rotator;
  struct wire_cst_DeviceCapabilities_Dome Dome;
  struct wire_cst_DeviceCapabilities_CoverCalibrator CoverCalibrator;
  struct wire_cst_DeviceCapabilities_Weather Weather;
  struct wire_cst_DeviceCapabilities_SafetyMonitor SafetyMonitor;
  struct wire_cst_DeviceCapabilities_Switch Switch;
} DeviceCapabilitiesKind;

typedef struct wire_cst_device_capabilities {
  int32_t tag;
  union DeviceCapabilitiesKind kind;
} wire_cst_device_capabilities;

typedef struct wire_cst_device_heartbeat_info {
  struct wire_cst_list_prim_u_8_strict *device_id;
  struct wire_cst_list_prim_u_8_strict *device_type;
  bool heartbeat_active;
  int64_t *last_successful_comm_ms;
  uint64_t interval_secs;
  uint64_t max_interval_secs;
  uint32_t failure_threshold;
  bool auto_reconnect;
  uint32_t max_reconnect_attempts;
} wire_cst_device_heartbeat_info;

typedef struct wire_cst_dome_status {
  bool connected;
  double azimuth;
  double *altitude;
  int32_t shutter_status;
  bool slewing;
  bool at_home;
  bool at_park;
  bool can_set_altitude;
  bool can_set_azimuth;
  bool can_set_shutter;
  bool can_slave;
  bool is_slaved;
} wire_cst_dome_status;

typedef struct wire_cst_EventPayload_Equipment {
  struct wire_cst_equipment_event *field0;
} wire_cst_EventPayload_Equipment;

typedef struct wire_cst_EventPayload_Imaging {
  struct wire_cst_imaging_event *field0;
} wire_cst_EventPayload_Imaging;

typedef struct wire_cst_EventPayload_Guiding {
  struct wire_cst_guiding_event *field0;
} wire_cst_EventPayload_Guiding;

typedef struct wire_cst_EventPayload_Sequencer {
  struct wire_cst_sequencer_event *field0;
} wire_cst_EventPayload_Sequencer;

typedef struct wire_cst_EventPayload_Safety {
  struct wire_cst_safety_event *field0;
} wire_cst_EventPayload_Safety;

typedef struct wire_cst_EventPayload_System {
  struct wire_cst_system_event *field0;
} wire_cst_EventPayload_System;

typedef struct wire_cst_EventPayload_PolarAlignment {
  struct wire_cst_polar_alignment_event *field0;
} wire_cst_EventPayload_PolarAlignment;

typedef struct wire_cst_EventPayload_PolarAlignmentStatus {
  struct wire_cst_polar_alignment_status *field0;
} wire_cst_EventPayload_PolarAlignmentStatus;

typedef struct wire_cst_EventPayload_PolarAlignmentImage {
  struct wire_cst_polar_alignment_image_event *field0;
} wire_cst_EventPayload_PolarAlignmentImage;

typedef struct wire_cst_EventPayload_DepthLock {
  struct wire_cst_depth_lock_event *field0;
} wire_cst_EventPayload_DepthLock;

typedef union EventPayloadKind {
  struct wire_cst_EventPayload_Equipment Equipment;
  struct wire_cst_EventPayload_Imaging Imaging;
  struct wire_cst_EventPayload_Guiding Guiding;
  struct wire_cst_EventPayload_Sequencer Sequencer;
  struct wire_cst_EventPayload_Safety Safety;
  struct wire_cst_EventPayload_System System;
  struct wire_cst_EventPayload_PolarAlignment PolarAlignment;
  struct wire_cst_EventPayload_PolarAlignmentStatus PolarAlignmentStatus;
  struct wire_cst_EventPayload_PolarAlignmentImage PolarAlignmentImage;
  struct wire_cst_EventPayload_DepthLock DepthLock;
} EventPayloadKind;

typedef struct wire_cst_event_payload {
  int32_t tag;
  union EventPayloadKind kind;
} wire_cst_event_payload;

typedef struct wire_cst_filter_wheel_status {
  bool connected;
  int32_t position;
  bool moving;
  int32_t filter_count;
  struct wire_cst_list_String *filter_names;
} wire_cst_filter_wheel_status;

typedef struct wire_cst_fits_linear_read_result {
  uint32_t width;
  uint32_t height;
  int32_t bitpix;
  struct wire_cst_list_prim_f_64_strict *linear_data;
  struct wire_cst_list_prim_u_8_strict *object_name;
  double *exposure_time;
  struct wire_cst_list_prim_u_8_strict *filter;
  double *ra;
  double *dec;
  struct wire_cst_list_prim_u_8_strict *date_obs;
  struct wire_cst_list_prim_u_8_strict *bayer_pattern;
} wire_cst_fits_linear_read_result;

typedef struct wire_cst_fits_read_result {
  uint32_t width;
  uint32_t height;
  int32_t bitpix;
  struct wire_cst_list_prim_u_8_strict *display_data;
  struct wire_cst_list_prim_u_32_strict *histogram;
  struct wire_cst_image_stats_result stats;
  struct wire_cst_list_prim_u_8_strict *object_name;
  double *exposure_time;
  struct wire_cst_list_prim_u_8_strict *filter;
  double *ra;
  double *dec;
  struct wire_cst_list_prim_u_8_strict *date_obs;
  struct wire_cst_list_prim_u_8_strict *bayer_pattern;
} wire_cst_fits_read_result;

typedef struct wire_cst_focuser_status {
  bool connected;
  int32_t position;
  bool moving;
  double *temperature;
  int32_t max_position;
  double step_size;
  bool is_absolute;
  bool has_temperature;
} wire_cst_focuser_status;

typedef struct wire_cst_indi_autofocus_result_api {
  int32_t best_position;
  double best_hfr;
  double curve_fit_quality;
  struct wire_cst_list_prim_u_8_strict *method_used;
  struct wire_cst_list_focus_data_point_api *data_points;
  double *temperature_celsius;
  bool backlash_applied;
  bool success;
  struct wire_cst_list_prim_u_8_strict *error_message;
} wire_cst_indi_autofocus_result_api;

typedef struct wire_cst_mount_site {
  double latitude_deg;
  double longitude_deg;
  double *elevation_m;
} wire_cst_mount_site;

typedef struct wire_cst_mount_site_capabilities {
  bool can_read_site;
  bool can_write_site;
  bool can_read_time;
  bool can_write_time;
} wire_cst_mount_site_capabilities;

typedef struct wire_cst_mount_status {
  bool connected;
  bool tracking;
  bool slewing;
  bool parked;
  bool *at_home;
  int32_t *side_of_pier;
  double right_ascension;
  double declination;
  double *altitude;
  double *azimuth;
  double *sidereal_time;
  int32_t *tracking_rate;
  bool can_park;
  bool can_slew;
  bool can_sync;
  bool can_pulse_guide;
  bool can_set_tracking_rate;
  struct wire_cst_list_record_string_field_availability *availability;
} wire_cst_mount_status;

typedef struct wire_cst_mount_time_info {
  int64_t utc_unix_seconds;
  double utc_offset_hours;
} wire_cst_mount_time_info;

typedef struct wire_cst_NightshadeError_DeviceNotFound {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_DeviceNotFound;

typedef struct wire_cst_NightshadeError_ConnectionFailed {
  struct wire_cst_list_prim_u_8_strict *device_id;
  struct wire_cst_list_prim_u_8_strict *reason;
} wire_cst_NightshadeError_ConnectionFailed;

typedef struct wire_cst_NightshadeError_AlreadyConnected {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_AlreadyConnected;

typedef struct wire_cst_NightshadeError_NotConnected {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_NotConnected;

typedef struct wire_cst_NightshadeError_DeviceDisconnected {
  struct wire_cst_list_prim_u_8_strict *device_id;
  struct wire_cst_list_prim_u_8_strict *reason;
} wire_cst_NightshadeError_DeviceDisconnected;

typedef struct wire_cst_NightshadeError_HardwareError {
  struct wire_cst_list_prim_u_8_strict *device_id;
  struct wire_cst_list_prim_u_8_strict *message;
  int32_t *error_code;
} wire_cst_NightshadeError_HardwareError;

typedef struct wire_cst_NightshadeError_CommunicationError {
  struct wire_cst_list_prim_u_8_strict *device_id;
  struct wire_cst_list_prim_u_8_strict *message;
} wire_cst_NightshadeError_CommunicationError;

typedef struct wire_cst_NightshadeError_Timeout {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_Timeout;

typedef struct wire_cst_NightshadeError_DeviceTimeout {
  struct wire_cst_list_prim_u_8_strict *device_id;
  struct wire_cst_list_prim_u_8_strict *operation;
  double timeout_secs;
} wire_cst_NightshadeError_DeviceTimeout;

typedef struct wire_cst_NightshadeError_ConnectionTimeout {
  struct wire_cst_list_prim_u_8_strict *device_id;
  double timeout_secs;
} wire_cst_NightshadeError_ConnectionTimeout;

typedef struct wire_cst_NightshadeError_InvalidParameter {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_InvalidParameter;

typedef struct wire_cst_NightshadeError_InvalidInput {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_InvalidInput;

typedef struct wire_cst_NightshadeError_InvalidDeviceId {
  struct wire_cst_list_prim_u_8_strict *device_id;
  struct wire_cst_list_prim_u_8_strict *reason;
} wire_cst_NightshadeError_InvalidDeviceId;

typedef struct wire_cst_NightshadeError_ParameterOutOfRange {
  struct wire_cst_list_prim_u_8_strict *param_name;
  struct wire_cst_list_prim_u_8_strict *value;
  struct wire_cst_list_prim_u_8_strict *min;
  struct wire_cst_list_prim_u_8_strict *max;
} wire_cst_NightshadeError_ParameterOutOfRange;

typedef struct wire_cst_NightshadeError_OperationFailed {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_OperationFailed;

typedef struct wire_cst_NightshadeError_NotSupported {
  struct wire_cst_list_prim_u_8_strict *device_id;
  struct wire_cst_list_prim_u_8_strict *operation;
} wire_cst_NightshadeError_NotSupported;

typedef struct wire_cst_NightshadeError_DeviceBusy {
  struct wire_cst_list_prim_u_8_strict *device_id;
  struct wire_cst_list_prim_u_8_strict *current_operation;
} wire_cst_NightshadeError_DeviceBusy;

typedef struct wire_cst_NightshadeError_ImageError {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_ImageError;

typedef struct wire_cst_NightshadeError_CameraError {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_CameraError;

typedef struct wire_cst_NightshadeError_ExposureFailed {
  struct wire_cst_list_prim_u_8_strict *camera_id;
  struct wire_cst_list_prim_u_8_strict *reason;
} wire_cst_NightshadeError_ExposureFailed;

typedef struct wire_cst_NightshadeError_DownloadFailed {
  struct wire_cst_list_prim_u_8_strict *camera_id;
  struct wire_cst_list_prim_u_8_strict *reason;
} wire_cst_NightshadeError_DownloadFailed;

typedef struct wire_cst_NightshadeError_IoError {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_IoError;

typedef struct wire_cst_NightshadeError_SerializationError {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_SerializationError;

typedef struct wire_cst_NightshadeError_PlateSolveError {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_PlateSolveError;

typedef struct wire_cst_NightshadeError_SequenceError {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_SequenceError;

typedef struct wire_cst_NightshadeError_AscomError {
  struct wire_cst_list_prim_u_8_strict *prog_id;
  struct wire_cst_list_prim_u_8_strict *message;
  int32_t error_code;
} wire_cst_NightshadeError_AscomError;

typedef struct wire_cst_NightshadeError_AlpacaError {
  struct wire_cst_list_prim_u_8_strict *base_url;
  uint32_t device_number;
  struct wire_cst_list_prim_u_8_strict *message;
  int32_t error_code;
} wire_cst_NightshadeError_AlpacaError;

typedef struct wire_cst_NightshadeError_IndiError {
  struct wire_cst_list_prim_u_8_strict *server;
  uint16_t port;
  struct wire_cst_list_prim_u_8_strict *device_name;
  struct wire_cst_list_prim_u_8_strict *message;
} wire_cst_NightshadeError_IndiError;

typedef struct wire_cst_NightshadeError_NativeError {
  struct wire_cst_list_prim_u_8_strict *vendor;
  struct wire_cst_list_prim_u_8_strict *message;
  int32_t error_code;
} wire_cst_NightshadeError_NativeError;

typedef struct wire_cst_NightshadeError_ComError {
  struct wire_cst_list_prim_u_8_strict *message;
  uint32_t hresult;
} wire_cst_NightshadeError_ComError;

typedef struct wire_cst_NightshadeError_Internal {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_Internal;

typedef struct wire_cst_NightshadeError_RuntimeInitFailed {
  struct wire_cst_list_prim_u_8_strict *field0;
} wire_cst_NightshadeError_RuntimeInitFailed;

typedef struct wire_cst_NightshadeError_ResourceExhausted {
  struct wire_cst_list_prim_u_8_strict *resource;
  struct wire_cst_list_prim_u_8_strict *message;
} wire_cst_NightshadeError_ResourceExhausted;

typedef union NightshadeErrorKind {
  struct wire_cst_NightshadeError_DeviceNotFound DeviceNotFound;
  struct wire_cst_NightshadeError_ConnectionFailed ConnectionFailed;
  struct wire_cst_NightshadeError_AlreadyConnected AlreadyConnected;
  struct wire_cst_NightshadeError_NotConnected NotConnected;
  struct wire_cst_NightshadeError_DeviceDisconnected DeviceDisconnected;
  struct wire_cst_NightshadeError_HardwareError HardwareError;
  struct wire_cst_NightshadeError_CommunicationError CommunicationError;
  struct wire_cst_NightshadeError_Timeout Timeout;
  struct wire_cst_NightshadeError_DeviceTimeout DeviceTimeout;
  struct wire_cst_NightshadeError_ConnectionTimeout ConnectionTimeout;
  struct wire_cst_NightshadeError_InvalidParameter InvalidParameter;
  struct wire_cst_NightshadeError_InvalidInput InvalidInput;
  struct wire_cst_NightshadeError_InvalidDeviceId InvalidDeviceId;
  struct wire_cst_NightshadeError_ParameterOutOfRange ParameterOutOfRange;
  struct wire_cst_NightshadeError_OperationFailed OperationFailed;
  struct wire_cst_NightshadeError_NotSupported NotSupported;
  struct wire_cst_NightshadeError_DeviceBusy DeviceBusy;
  struct wire_cst_NightshadeError_ImageError ImageError;
  struct wire_cst_NightshadeError_CameraError CameraError;
  struct wire_cst_NightshadeError_ExposureFailed ExposureFailed;
  struct wire_cst_NightshadeError_DownloadFailed DownloadFailed;
  struct wire_cst_NightshadeError_IoError IoError;
  struct wire_cst_NightshadeError_SerializationError SerializationError;
  struct wire_cst_NightshadeError_PlateSolveError PlateSolveError;
  struct wire_cst_NightshadeError_SequenceError SequenceError;
  struct wire_cst_NightshadeError_AscomError AscomError;
  struct wire_cst_NightshadeError_AlpacaError AlpacaError;
  struct wire_cst_NightshadeError_IndiError IndiError;
  struct wire_cst_NightshadeError_NativeError NativeError;
  struct wire_cst_NightshadeError_ComError ComError;
  struct wire_cst_NightshadeError_Internal Internal;
  struct wire_cst_NightshadeError_RuntimeInitFailed RuntimeInitFailed;
  struct wire_cst_NightshadeError_ResourceExhausted ResourceExhausted;
} NightshadeErrorKind;

typedef struct wire_cst_nightshade_error {
  int32_t tag;
  union NightshadeErrorKind kind;
} wire_cst_nightshade_error;

typedef struct wire_cst_nightshade_event {
  uint64_t event_id;
  int64_t timestamp;
  int32_t severity;
  int32_t category;
  struct wire_cst_event_payload payload;
  uint64_t *caused_by;
  struct wire_cst_list_prim_u_8_strict *correlation_id;
  struct wire_cst_list_prim_u_8_strict *device_id;
} wire_cst_nightshade_event;

typedef struct wire_cst_phd_2_calibration_data {
  bool is_calibrated;
  double *ra_angle;
  double *dec_angle;
  double *ra_rate;
  double *dec_rate;
} wire_cst_phd_2_calibration_data;

typedef struct wire_cst_phd_2_star_image {
  uint32_t frame;
  uint32_t width;
  uint32_t height;
  double star_x;
  double star_y;
  struct wire_cst_list_prim_u_8_strict *pixels;
} wire_cst_phd_2_star_image;

typedef struct wire_cst_phd_2_status {
  bool connected;
  struct wire_cst_list_prim_u_8_strict *state;
  double rms_ra;
  double rms_dec;
  double rms_total;
  double snr;
  double star_mass;
  double pixel_scale;
} wire_cst_phd_2_status;

typedef struct wire_cst_plate_solve_result {
  bool success;
  double ra;
  double dec;
  double pixel_scale;
  double rotation;
  double field_width;
  double field_height;
  double solve_time_secs;
  struct wire_cst_list_prim_u_8_strict *error;
  double cd1_1;
  double cd1_2;
  double cd2_1;
  double cd2_2;
  uint32_t sip_a_order;
  uint32_t sip_b_order;
  struct wire_cst_list_prim_f_64_strict *sip_a_coeffs;
  struct wire_cst_list_prim_f_64_strict *sip_b_coeffs;
  uint32_t sip_ap_order;
  uint32_t sip_bp_order;
  struct wire_cst_list_prim_f_64_strict *sip_ap_coeffs;
  struct wire_cst_list_prim_f_64_strict *sip_bp_coeffs;
} wire_cst_plate_solve_result;

typedef struct wire_cst_plate_solver_detection {
  struct wire_cst_list_prim_u_8_strict *astap_path;
  struct wire_cst_list_prim_u_8_strict *astrometry_path;
  struct wire_cst_list_prim_u_8_strict *catalog_name;
  float *catalog_magnitude_limit;
  struct wire_cst_list_prim_u_8_strict *catalog_path;
} wire_cst_plate_solver_detection;

typedef struct wire_cst_plate_solver_info {
  struct wire_cst_list_prim_u_8_strict *path;
  struct wire_cst_list_prim_u_8_strict *flavour;
  struct wire_cst_list_prim_u_8_strict *version_line;
} wire_cst_plate_solver_info;

typedef struct wire_cst_qhy_discovery_status {
  bool sdk_available;
  bool discovery_enabled;
  uint64_t timeout_ms;
} wire_cst_qhy_discovery_status;

typedef struct wire_cst_quality_frame_metrics_api {
  double median;
  double mean;
  double std_dev;
  double mad;
  double background;
  double noise;
  double snr;
  double dynamic_range_p1_p99;
  double low_clip_percent;
  double high_clip_percent;
  double uniformity_cv;
  double gradient_x;
  double gradient_y;
  struct wire_cst_list_prim_u_8_strict *processing_tier;
  uint32_t processing_ms;
} wire_cst_quality_frame_metrics_api;

typedef struct wire_cst_quality_maps_result_api {
  struct wire_cst_quality_frame_metrics_api frame;
  struct wire_cst_list_quality_tile_metric_api *tiles;
} wire_cst_quality_maps_result_api;

typedef struct wire_cst_record_i_32_f_64 {
  int32_t field0;
  double field1;
} wire_cst_record_i_32_f_64;

typedef struct wire_cst_record_i_32_i_32 {
  int32_t field0;
  int32_t field1;
} wire_cst_record_i_32_i_32;

typedef struct wire_cst_record_i_32_list_string {
  int32_t field0;
  struct wire_cst_list_String *field1;
} wire_cst_record_i_32_list_string;

typedef struct wire_cst_record_i_64_bool {
  int64_t field0;
  bool field1;
} wire_cst_record_i_64_bool;

typedef struct wire_cst_record_u_64_u_64_u_32_bool {
  uint64_t field0;
  uint64_t field1;
  uint32_t field2;
  bool field3;
} wire_cst_record_u_64_u_64_u_32_bool;

typedef struct wire_cst_rotator_status {
  bool connected;
  double position;
  bool moving;
  double mechanical_position;
  bool is_moving;
  bool can_reverse;
} wire_cst_rotator_status;

typedef struct wire_cst_safety_status {
  bool connected;
  bool is_safe;
} wire_cst_safety_status;

typedef struct wire_cst_secondary_rig_status_api {
  bool armed;
  bool running;
  struct wire_cst_list_prim_u_8_strict *camera_id;
  struct wire_cst_list_prim_u_8_strict *rig_label;
  uint32_t frames_captured;
  uint32_t frames_aborted;
  uint32_t *planned_frames;
  bool waiting_for_dither;
  bool exposing;
  bool dither_pending;
  uint32_t forced_proceeds;
  struct wire_cst_list_prim_u_8_strict *last_error;
} wire_cst_secondary_rig_status_api;

typedef struct wire_cst_sequencer_state {
  struct wire_cst_list_prim_u_8_strict *state;
  struct wire_cst_list_prim_u_8_strict *current_node_id;
  struct wire_cst_list_prim_u_8_strict *current_node_name;
  uint32_t total_exposures;
  uint32_t completed_exposures;
  double total_integration_secs;
  double elapsed_secs;
  double *estimated_remaining_secs;
  struct wire_cst_list_prim_u_8_strict *current_target;
  struct wire_cst_list_prim_u_8_strict *current_filter;
  struct wire_cst_list_prim_u_8_strict *message;
} wire_cst_sequencer_state;

typedef struct wire_cst_session_state {
  bool is_active;
  int64_t *start_time;
  struct wire_cst_list_prim_u_8_strict *target_name;
  double *target_ra;
  double *target_dec;
  uint32_t total_exposures;
  uint32_t completed_exposures;
  double total_integration_secs;
  struct wire_cst_list_prim_u_8_strict *current_filter;
  bool is_guiding;
  bool is_capturing;
  bool is_dithering;
} wire_cst_session_state;

typedef struct wire_cst_simulated_camera {
  struct wire_cst_camera_status status;
} wire_cst_simulated_camera;

typedef struct wire_cst_simulated_dome {
  struct wire_cst_dome_status status;
} wire_cst_simulated_dome;

typedef struct wire_cst_simulated_filter_wheel {
  struct wire_cst_filter_wheel_status status;
} wire_cst_simulated_filter_wheel;

typedef struct wire_cst_simulated_focuser {
  struct wire_cst_focuser_status status;
} wire_cst_simulated_focuser;

typedef struct wire_cst_simulated_mount {
  struct wire_cst_mount_status status;
} wire_cst_simulated_mount;

typedef struct wire_cst_simulated_rotator {
  struct wire_cst_rotator_status status;
} wire_cst_simulated_rotator;

typedef struct wire_cst_simulated_safety_monitor {
  struct wire_cst_safety_status status;
} wire_cst_simulated_safety_monitor;

typedef struct wire_cst_weather_conditions {
  double *temperature;
  double *humidity;
  double *pressure;
  double *cloud_cover;
  double *dew_point;
  double *wind_speed;
  double *wind_direction;
  double *sky_quality;
  double *sky_temperature;
  double *rain_rate;
} wire_cst_weather_conditions;

typedef struct wire_cst_simulated_weather {
  bool connected;
  struct wire_cst_weather_conditions conditions;
} wire_cst_simulated_weather;

typedef struct wire_cst_solve_hints {
  double *focal_length_mm;
  struct wire_cst_record_f_64_f_64 *pixel_size_um;
  struct wire_cst_record_i_32_i_32 binning;
} wire_cst_solve_hints;

typedef struct wire_cst_star_detection_result_api {
  struct wire_cst_list_detected_star_info *stars;
  uint32_t star_count;
  double median_hfr;
  double median_fwhm;
  double median_snr;
  double *median_eccentricity;
  double background;
  double noise;
} wire_cst_star_detection_result_api;

typedef struct wire_cst_xisf_read_result {
  uint32_t width;
  uint32_t height;
  uint32_t channels;
  struct wire_cst_list_prim_u_8_strict *display_data;
  struct wire_cst_list_prim_u_32_strict *histogram;
  struct wire_cst_image_stats_result stats;
  struct wire_cst_list_record_string_string *properties;
} wire_cst_xisf_read_result;

void frbgen_nightshade_bridge_wire__crate__api__finishing_analyze__api_analyze_night(int64_t port_,
                                                                                     struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_apply_stretch(int64_t port_,
                                                                           struct wire_cst_list_prim_u_8_strict *file_path,
                                                                           struct wire_cst_stretch_params_api *params);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__imaging__api_auto_stretch_color_image(uint32_t width,
                                                                                                      uint32_t height,
                                                                                                      struct wire_cst_list_prim_u_16_loose *data);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__imaging__api_auto_stretch_image(uint32_t width,
                                                                                                uint32_t height,
                                                                                                struct wire_cst_list_prim_u_16_loose *data);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__mosaic__api_broadcast_deactivate(void);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__mosaic__api_broadcast_get_active(void);

void frbgen_nightshade_bridge_wire__crate__api__post_session__entrypoints__api_build_master_flat(int64_t port_,
                                                                                                 struct wire_cst_list_prim_u_8_strict *args_json);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_build_sequence(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                            struct wire_cst_list_prim_u_8_strict *name,
                                                                                                            struct wire_cst_list_prim_u_8_strict *description,
                                                                                                            struct wire_cst_list_String *node_jsons,
                                                                                                            struct wire_cst_list_prim_u_8_strict *root_node_id);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_builtin_guider_get_config(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_builtin_guider_get_tracked_stars_json(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_builtin_guider_set_config(int64_t port_,
                                                                                    double exposure_secs,
                                                                                    int32_t gain,
                                                                                    int32_t offset,
                                                                                    int32_t binning,
                                                                                    uint32_t calibration_ms,
                                                                                    uint64_t settle_sleep_ms,
                                                                                    double min_pulse_ms,
                                                                                    double max_pulse_ms);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__mosaic__api_calculate_altitude(double ra_hours,
                                                                                                          double dec_degrees,
                                                                                                          double latitude,
                                                                                                          double longitude,
                                                                                                          int64_t time_unix_millis);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_calculate_auto_stretch(int64_t port_,
                                                                                    struct wire_cst_list_prim_u_8_strict *file_path);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_calculate_hfr(int64_t port_,
                                                                           struct wire_cst_list_prim_u_8_strict *file_path);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_calculate_histogram(int64_t port_,
                                                                                 struct wire_cst_list_prim_u_8_strict *file_path,
                                                                                 uint32_t _bins,
                                                                                 uint8_t logarithmic);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__mosaic__api_calculate_mosaic_area(double panel_width_arcmin,
                                                                                                             double panel_height_arcmin,
                                                                                                             uint32_t panels_horizontal,
                                                                                                             uint32_t panels_vertical);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__mosaic__api_calculate_mosaic_panels(double center_ra,
                                                                                                               double center_dec,
                                                                                                               double panel_width_arcmin,
                                                                                                               double panel_height_arcmin,
                                                                                                               double overlap_percent,
                                                                                                               double rotation,
                                                                                                               uint32_t panels_horizontal,
                                                                                                               uint32_t panels_vertical);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__imaging__api_calibrate_image_data(uint32_t width,
                                                                                                  uint32_t height,
                                                                                                  struct wire_cst_list_prim_u_16_loose *light_data,
                                                                                                  struct wire_cst_list_prim_u_16_strict *dark_data,
                                                                                                  struct wire_cst_list_prim_u_16_strict *flat_data,
                                                                                                  struct wire_cst_list_prim_u_16_strict *bias_data);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_calibrate_image_file(int64_t port_,
                                                                                  struct wire_cst_list_prim_u_8_strict *light_path,
                                                                                  struct wire_cst_list_prim_u_8_strict *dark_path,
                                                                                  struct wire_cst_list_prim_u_8_strict *flat_path,
                                                                                  struct wire_cst_list_prim_u_8_strict *bias_path,
                                                                                  struct wire_cst_list_prim_u_8_strict *output_path);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_camera_cancel_exposure(int64_t port_,
                                                                                    struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__camera__api_camera_capture_preview(int64_t port_,
                                                                                            struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__camera__api_camera_get_recommended_settings(int64_t port_,
                                                                                                     struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__camera__api_camera_set_readout_mode(int64_t port_,
                                                                                             struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                             int32_t mode_index);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_camera_start_exposure(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                   double duration_secs,
                                                                                   int32_t gain,
                                                                                   int32_t offset,
                                                                                   int32_t bin_x,
                                                                                   int32_t bin_y);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_camera_start_exposure_configured(int64_t port_,
                                                                                              struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                              double duration_secs,
                                                                                              int32_t *gain,
                                                                                              int32_t *offset,
                                                                                              int32_t bin_x,
                                                                                              int32_t bin_y,
                                                                                              uint32_t *start_x,
                                                                                              uint32_t *start_y,
                                                                                              uint32_t *width,
                                                                                              uint32_t *height,
                                                                                              struct wire_cst_list_prim_u_8_strict *frame_type);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_cancel_autofocus(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_cancel_focuser_backlash_calibration(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_clear_device_image(int64_t port_,
                                                                                struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__finishing_analyze__api_color_calibrate(int64_t port_,
                                                                                       struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__finishing_combine__api_combine_channels(int64_t port_,
                                                                                        struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_combine_master_frames(int64_t port_,
                                                                                   struct wire_cst_list_String *input_paths,
                                                                                   struct wire_cst_list_prim_u_8_strict *kind,
                                                                                   struct wire_cst_api_combine_method *method,
                                                                                   struct wire_cst_list_prim_u_8_strict *output_type,
                                                                                   struct wire_cst_list_prim_u_8_strict *output_path);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_compute_fits_quality_maps(int64_t port_,
                                                                                       struct wire_cst_list_prim_u_8_strict *file_path,
                                                                                       uint32_t grid_rows,
                                                                                       uint32_t grid_cols,
                                                                                       uint32_t low_clip_adu,
                                                                                       uint32_t high_clip_adu);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_compute_last_capture_quality_maps(int64_t port_,
                                                                                               struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                               uint32_t grid_rows,
                                                                                               uint32_t grid_cols,
                                                                                               uint32_t low_clip_adu,
                                                                                               uint32_t high_clip_adu);

void frbgen_nightshade_bridge_wire__crate__api__connection__api_connect_device(int64_t port_,
                                                                               int32_t device_type,
                                                                               struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_calibrator_off(int64_t port_,
                                                                                                               struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_calibrator_on(int64_t port_,
                                                                                                              struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                              int32_t brightness);

void frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_close_cover(int64_t port_,
                                                                                                            struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_get_brightness(int64_t port_,
                                                                                                               struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_get_calibrator_state(int64_t port_,
                                                                                                                     struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_get_cover_state(int64_t port_,
                                                                                                                struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_get_max_brightness(int64_t port_,
                                                                                                                   struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_get_status(int64_t port_,
                                                                                                           struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_halt_cover(int64_t port_,
                                                                                                           struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_open_cover(int64_t port_,
                                                                                                           struct wire_cst_list_prim_u_8_strict *device_id);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_autofocus_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                                   struct wire_cst_list_prim_u_8_strict *name,
                                                                                                                   int32_t step_size,
                                                                                                                   uint32_t steps_out,
                                                                                                                   double exposure_duration,
                                                                                                                   struct wire_cst_list_prim_u_8_strict *method);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_center_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                                struct wire_cst_list_prim_u_8_strict *name,
                                                                                                                uint8_t use_target_coords,
                                                                                                                double accuracy_arcsec,
                                                                                                                uint32_t max_attempts,
                                                                                                                double exposure_duration);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_cool_camera_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                                     struct wire_cst_list_prim_u_8_strict *name,
                                                                                                                     double target_temp,
                                                                                                                     double *duration_mins);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_delay_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                               struct wire_cst_list_prim_u_8_strict *name,
                                                                                                               double seconds);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_dither_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                                struct wire_cst_list_prim_u_8_strict *name,
                                                                                                                double pixels,
                                                                                                                double settle_pixels,
                                                                                                                double settle_time,
                                                                                                                double settle_timeout,
                                                                                                                uint8_t ra_only);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_exposure_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                                  struct wire_cst_list_prim_u_8_strict *name,
                                                                                                                  double duration_secs,
                                                                                                                  uint32_t count,
                                                                                                                  struct wire_cst_list_prim_u_8_strict *filter,
                                                                                                                  int32_t *filter_index,
                                                                                                                  int32_t *gain,
                                                                                                                  int32_t *offset,
                                                                                                                  int32_t binning,
                                                                                                                  uint32_t *dither_every);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_filter_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                                struct wire_cst_list_prim_u_8_strict *name,
                                                                                                                struct wire_cst_list_prim_u_8_strict *filter_name);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_loop_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                              struct wire_cst_list_prim_u_8_strict *name,
                                                                                                              uint32_t *iterations,
                                                                                                              struct wire_cst_list_prim_u_8_strict *condition,
                                                                                                              struct wire_cst_list_String *children);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_notification_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                                      struct wire_cst_list_prim_u_8_strict *name,
                                                                                                                      struct wire_cst_list_prim_u_8_strict *title,
                                                                                                                      struct wire_cst_list_prim_u_8_strict *message,
                                                                                                                      struct wire_cst_list_prim_u_8_strict *level);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_park_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                              struct wire_cst_list_prim_u_8_strict *name);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_rotator_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                                 struct wire_cst_list_prim_u_8_strict *name,
                                                                                                                 double target_angle,
                                                                                                                 uint8_t relative);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_script_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                                struct wire_cst_list_prim_u_8_strict *name,
                                                                                                                struct wire_cst_list_prim_u_8_strict *script_path,
                                                                                                                struct wire_cst_list_String *arguments,
                                                                                                                uint32_t *timeout_secs);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_slew_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                              struct wire_cst_list_prim_u_8_strict *name,
                                                                                                              uint8_t use_target_coords,
                                                                                                              double *custom_ra,
                                                                                                              double *custom_dec);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_target_group_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                                      struct wire_cst_list_prim_u_8_strict *name,
                                                                                                                      struct wire_cst_list_prim_u_8_strict *target_name,
                                                                                                                      double ra_hours,
                                                                                                                      double dec_degrees,
                                                                                                                      double *rotation,
                                                                                                                      double *min_altitude,
                                                                                                                      double *max_altitude,
                                                                                                                      int32_t priority,
                                                                                                                      struct wire_cst_list_String *children);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_target_header_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                                       struct wire_cst_list_prim_u_8_strict *name,
                                                                                                                       struct wire_cst_list_prim_u_8_strict *target_name,
                                                                                                                       double ra_hours,
                                                                                                                       double dec_degrees,
                                                                                                                       double *rotation,
                                                                                                                       double *min_altitude,
                                                                                                                       double *max_altitude,
                                                                                                                       int32_t priority,
                                                                                                                       int64_t *start_after,
                                                                                                                       int64_t *end_before,
                                                                                                                       struct wire_cst_list_prim_u_8_strict *mosaic_panel_json,
                                                                                                                       struct wire_cst_list_prim_u_8_strict *integration_budget_json,
                                                                                                                       struct wire_cst_list_String *children);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_unpark_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                                struct wire_cst_list_prim_u_8_strict *name);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_wait_time_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                                   struct wire_cst_list_prim_u_8_strict *name,
                                                                                                                   int64_t *wait_until,
                                                                                                                   struct wire_cst_list_prim_u_8_strict *twilight_type);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_warm_camera_node(struct wire_cst_list_prim_u_8_strict *id,
                                                                                                                     struct wire_cst_list_prim_u_8_strict *name,
                                                                                                                     double rate_per_min,
                                                                                                                     double *target_temp);

void frbgen_nightshade_bridge_wire__crate__api__darkroom__entrypoints__api_darkroom_cancel(int64_t port_,
                                                                                           struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__darkroom__entrypoints__api_darkroom_registry(int64_t port_,
                                                                                             struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__darkroom__entrypoints__api_darkroom_render_export(int64_t port_,
                                                                                                  struct wire_cst_list_prim_u_8_strict *recipe_json,
                                                                                                  struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__darkroom__entrypoints__api_darkroom_render_preview(int64_t port_,
                                                                                                   struct wire_cst_list_prim_u_8_strict *recipe_json,
                                                                                                   struct wire_cst_list_prim_u_8_strict *context_json);

void frbgen_nightshade_bridge_wire__crate__api__darkroom__entrypoints__api_darkroom_validate(int64_t port_,
                                                                                             struct wire_cst_list_prim_u_8_strict *recipe_json,
                                                                                             struct wire_cst_list_prim_u_8_strict *context_json);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_debayer_fits_file(int64_t port_,
                                                                               struct wire_cst_list_prim_u_8_strict *file_path,
                                                                               int32_t pattern,
                                                                               int32_t algorithm);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__imaging__api_debayer_image(uint32_t width,
                                                                                           uint32_t height,
                                                                                           struct wire_cst_list_prim_u_16_loose *data,
                                                                                           struct wire_cst_list_prim_u_8_strict *pattern_str,
                                                                                           struct wire_cst_list_prim_u_8_strict *algo_str);

void frbgen_nightshade_bridge_wire__crate__api__finishing_enhance__api_deconvolve_preview(int64_t port_,
                                                                                          struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_defect_map_apply(int64_t port_,
                                                                              struct wire_cst_list_prim_u_8_strict *camera_id,
                                                                              bool apply_during_capture);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_defect_map_build(int64_t port_,
                                                                              struct wire_cst_list_prim_u_8_strict *camera_id,
                                                                              struct wire_cst_list_String *dark_frame_paths,
                                                                              double sensor_temperature_celsius);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_defect_map_clear(int64_t port_,
                                                                              struct wire_cst_list_prim_u_8_strict *camera_id,
                                                                              uint32_t width,
                                                                              uint32_t height,
                                                                              double sensor_temperature_celsius);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_defect_map_get_status(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *camera_id,
                                                                                   uint32_t width,
                                                                                   uint32_t height,
                                                                                   double sensor_temperature_celsius);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__storage__api_delete_profile(struct wire_cst_list_prim_u_8_strict *profile_id);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_check_measurement(struct wire_cst_api_depth_measurement *measurement);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_create_goal(struct wire_cst_list_prim_u_8_strict *goal_id,
                                                                                                     struct wire_cst_api_depth_goal_definition *definition);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_get_goal(struct wire_cst_list_prim_u_8_strict *goal_id);

void frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_goal_curve(int64_t port_,
                                                                                    struct wire_cst_list_prim_u_8_strict *goal_id,
                                                                                    uint32_t max_points);

void frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_ingest_frame(int64_t port_,
                                                                                      struct wire_cst_list_prim_u_8_strict *goal_id,
                                                                                      struct wire_cst_list_prim_u_8_strict *path);

void frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_inspect_reference(int64_t port_,
                                                                                           struct wire_cst_list_prim_u_8_strict *path);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_list_goals(void);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_remove_goal(struct wire_cst_list_prim_u_8_strict *goal_id,
                                                                                                     uint64_t expected_revision);

void frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_replay_goal(int64_t port_,
                                                                                     struct wire_cst_list_prim_u_8_strict *goal_id);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_revise_goal(struct wire_cst_list_prim_u_8_strict *goal_id,
                                                                                                     uint64_t expected_revision,
                                                                                                     struct wire_cst_api_depth_goal_definition *definition);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_set_goal_preferences(struct wire_cst_list_prim_u_8_strict *goal_id,
                                                                                                              uint64_t expected_revision,
                                                                                                              bool enabled,
                                                                                                              bool automatic_completion);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_sky_rectangle(struct wire_cst_api_reference_geometry *reference,
                                                                                                       double x0,
                                                                                                       double y0,
                                                                                                       double x1,
                                                                                                       double y1);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_status(void);

void frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_suggest_floor(int64_t port_,
                                                                                       struct wire_cst_list_prim_u_8_strict *reference_path,
                                                                                       struct wire_cst_list_prim_u_8_strict *dark_path,
                                                                                       struct wire_cst_list_prim_u_8_strict *flat_path,
                                                                                       double scale_arcsec,
                                                                                       double *pixel_scale_arcsec);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_detect_stars_in_file(int64_t port_,
                                                                                  struct wire_cst_list_prim_u_8_strict *file_path,
                                                                                  struct wire_cst_star_detection_config_api *config);

void frbgen_nightshade_bridge_wire__crate__api__finishing_analyze__api_detect_stars_photometry(int64_t port_,
                                                                                               struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__api_version__api_device_supports_action(int64_t port_,
                                                                                        struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                        struct wire_cst_list_prim_u_8_strict *action);

void frbgen_nightshade_bridge_wire__crate__api__api_version__api_device_supports_version(int64_t port_,
                                                                                         struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                         uint32_t required_version);

void frbgen_nightshade_bridge_wire__crate__api__difference_image__api_difference_image(int64_t port_,
                                                                                       struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__difference_image__api_difference_tile_center(int64_t port_,
                                                                                             struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__connection__api_disconnect_device(int64_t port_,
                                                                                  int32_t device_type,
                                                                                  struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__discovery__api_discover_alpaca_at_address(int64_t port_,
                                                                                          struct wire_cst_list_prim_u_8_strict *host,
                                                                                          uint16_t port);

void frbgen_nightshade_bridge_wire__crate__api__discovery__api_discover_alpaca_devices(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__discovery__api_discover_devices(int64_t port_,
                                                                                int32_t device_type);

void frbgen_nightshade_bridge_wire__crate__api__discovery__api_discover_indi_at_address(int64_t port_,
                                                                                        struct wire_cst_list_prim_u_8_strict *host,
                                                                                        uint16_t port);

void frbgen_nightshade_bridge_wire__crate__api__discovery__api_discover_indi_common_hosts(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__discovery__api_discover_indi_localhost(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__discovery__api_discover_indi_network(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_abort_slew(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_close_shutter(int64_t port_,
                                                                                      struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_find_home(int64_t port_,
                                                                                  struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_get_azimuth(int64_t port_,
                                                                                    struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_get_shutter_status(int64_t port_,
                                                                                           struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_is_slewing(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_open_shutter(int64_t port_,
                                                                                     struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_park(int64_t port_,
                                                                             struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_set_slaved(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                   bool slaved);

void frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_slew_to_azimuth(int64_t port_,
                                                                                        struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                        double azimuth);

void frbgen_nightshade_bridge_wire__crate__api__finishing_combine__api_drizzle_integrate(int64_t port_,
                                                                                         struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__session__api_end_session(int64_t port_);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__sequencer__mosaic__api_estimate_mosaic_time(uint32_t total_panels,
                                                                                                            double exposure_secs,
                                                                                                            uint32_t exposures_per_panel,
                                                                                                            double overhead_per_panel_secs);

void frbgen_nightshade_bridge_wire__crate__api__event_stream__api_event_stream(int64_t port_,
                                                                               struct wire_cst_list_prim_u_8_strict *sink);

void frbgen_nightshade_bridge_wire__crate__api__init__api_export_logs(int64_t port_,
                                                                      struct wire_cst_list_prim_u_8_strict *output_path);

void frbgen_nightshade_bridge_wire__crate__api__finishing_enhance__api_extract_background(int64_t port_,
                                                                                          struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__filter_wheel__api_filterwheel_get_names(int64_t port_,
                                                                                                             struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__filter_wheel__api_filterwheel_set_by_name(int64_t port_,
                                                                                                               struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                               struct wire_cst_list_prim_u_8_strict *name);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__filter_wheel__api_filterwheel_set_filter_names(int64_t port_,
                                                                                                                    struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                                    struct wire_cst_list_String *names);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__filter_wheel__api_filterwheel_set_position(int64_t port_,
                                                                                                                struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                                int32_t position);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__focuser__api_focuser_halt(int64_t port_,
                                                                                               struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__focuser__api_focuser_move_relative(int64_t port_,
                                                                                                        struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                        int32_t delta);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__focuser__api_focuser_move_to(int64_t port_,
                                                                                                  struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                  int32_t position);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_generate_filename(int64_t port_,
                                                                               struct wire_cst_list_prim_u_8_strict *pattern,
                                                                               struct wire_cst_list_prim_u_8_strict *base_dir,
                                                                               struct wire_cst_list_prim_u_8_strict *target,
                                                                               struct wire_cst_list_prim_u_8_strict *filter,
                                                                               double exposure_time,
                                                                               int32_t frame_type,
                                                                               uint32_t frame_number,
                                                                               int32_t *gain,
                                                                               int32_t *offset,
                                                                               double *temperature,
                                                                               uint32_t binning_x,
                                                                               uint32_t binning_y,
                                                                               struct wire_cst_list_prim_u_8_strict *camera,
                                                                               struct wire_cst_list_prim_u_8_strict *telescope,
                                                                               struct wire_cst_list_prim_u_8_strict *extension);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_generate_fits_thumbnail(int64_t port_,
                                                                                     struct wire_cst_list_prim_u_8_strict *file_path,
                                                                                     uint32_t max_size);

void frbgen_nightshade_bridge_wire__crate__api__storage__api_get_active_profile(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_camera_capabilities(int64_t port_,
                                                                                         struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__camera__api_get_camera_status(int64_t port_,
                                                                                                   struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__connection__api_get_connected_devices(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_cover_calibrator_capabilities(int64_t port_,
                                                                                                   struct wire_cst_list_prim_u_8_strict *device_id);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__init__api_get_current_log_file(void);

void frbgen_nightshade_bridge_wire__crate__api__api_version__api_get_device_api_version(int64_t port_,
                                                                                        struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_device_capabilities(int64_t port_,
                                                                                         struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__connection__api_get_device_display_name(int64_t port_,
                                                                                        struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__heartbeat__api_get_device_health(int64_t port_,
                                                                                 struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__heartbeat__api_get_device_heartbeat_info(int64_t port_,
                                                                                         struct wire_cst_list_prim_u_8_strict *device_id);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_device_quirks(struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_dome_capabilities(int64_t port_,
                                                                                       struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_get_dome_status(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *device_id);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__event_stream__api_get_dropped_event_count(void);

void frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_filterwheel_capabilities(int64_t port_,
                                                                                              struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__filter_wheel__api_get_filterwheel_status(int64_t port_,
                                                                                                              struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_focuser_capabilities(int64_t port_,
                                                                                          struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__focuser__api_get_focuser_status(int64_t port_,
                                                                                                     struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__heartbeat__api_get_heartbeat_config_for_type(int64_t port_,
                                                                                             int32_t device_type);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__imaging__api_get_image_stats(uint32_t width,
                                                                                             uint32_t height,
                                                                                             struct wire_cst_list_prim_u_16_loose *data);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_get_last_image(int64_t port_,
                                                                            struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_get_last_raw_image_data(int64_t port_,
                                                                                     struct wire_cst_list_prim_u_8_strict *device_id);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__storage__api_get_location(void);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__init__api_get_log_directory(void);

void frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_mount_capabilities(int64_t port_,
                                                                                        struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_get_mount_status(int64_t port_,
                                                                                                 struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_get_next_frame_number(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *base_dir,
                                                                                   struct wire_cst_list_prim_u_8_strict *pattern,
                                                                                   struct wire_cst_list_prim_u_8_strict *target,
                                                                                   struct wire_cst_list_prim_u_8_strict *filter,
                                                                                   int32_t frame_type);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_get_plate_solver_path(void);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__storage__api_get_profiles(void);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_qhy_discovery_status(void);

void frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_rotator_capabilities(int64_t port_,
                                                                                          struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__rotator__api_get_rotator_status(int64_t port_,
                                                                                                     struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_safety_monitor_capabilities(int64_t port_,
                                                                                                 struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__environment__api_get_safety_monitor_status(int64_t port_,
                                                                                                    struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__session__api_get_session_state(int64_t port_);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__storage__api_get_settings(void);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_get_star_crops_from_last_image(int64_t port_,
                                                                                            struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                            uint32_t max_crops);

void frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_switch_capabilities(int64_t port_,
                                                                                         struct wire_cst_list_prim_u_8_strict *device_id);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__init__api_get_version(void);

void frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_weather_capabilities(int64_t port_,
                                                                                          struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__environment__api_get_weather_conditions(int64_t port_,
                                                                                                 struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_deselect_star(int64_t port_,
                                                                               struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_dither(int64_t port_,
                                                                        struct wire_cst_list_prim_u_8_strict *device_id,
                                                                        double amount,
                                                                        uint8_t ra_only,
                                                                        double settle_pixels,
                                                                        double settle_time,
                                                                        double settle_timeout);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_find_star(int64_t port_,
                                                                           struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_get_calibration(int64_t port_,
                                                                                 struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_get_lock_position(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_get_star_image(int64_t port_,
                                                                                struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                uint32_t size);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_get_status(int64_t port_,
                                                                            struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_loop(int64_t port_,
                                                                      struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_set_lock_position(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                   double x,
                                                                                   double y,
                                                                                   bool exact);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_start_guiding(int64_t port_,
                                                                               struct wire_cst_list_prim_u_8_strict *device_id,
                                                                               double settle_pixels,
                                                                               double settle_time,
                                                                               double settle_timeout);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_stop(int64_t port_,
                                                                      struct wire_cst_list_prim_u_8_strict *device_id);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__init__api_init(void);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__storage__api_init_profile_storage(struct wire_cst_list_prim_u_8_strict *storage_path);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__storage__api_init_settings_storage(struct wire_cst_list_prim_u_8_strict *storage_path);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__init__api_init_with_logging(struct wire_cst_list_prim_u_8_strict *log_directory);

void frbgen_nightshade_bridge_wire__crate__api__post_session__entrypoints__api_integrate_session(int64_t port_,
                                                                                                 struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__api_invalidate_discovery_cache(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__connection__api_is_device_connected(int64_t port_,
                                                                                    int32_t device_type,
                                                                                    struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__heartbeat__api_is_heartbeat_active(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *device_id);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__phd2__api_is_phd2_running(void);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_is_plate_solver_available(void);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_is_qhy_discovery_enabled(void);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_launch_phd2(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__init__api_list_log_files(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_live_stacking_config_default(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__storage__api_load_profile(int64_t port_,
                                                                          struct wire_cst_list_prim_u_8_strict *profile_id);

void frbgen_nightshade_bridge_wire__crate__api__post_session__entrypoints__api_master_accumulate(int64_t port_,
                                                                                                 struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_find_home(int64_t port_,
                                                                                                struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_park(int64_t port_,
                                                                                           struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_pulse_guide(int64_t port_,
                                                                                                  struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                  struct wire_cst_list_prim_u_8_strict *direction,
                                                                                                  int32_t duration_ms);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_set_tracking(int64_t port_,
                                                                                                   struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                   uint8_t enabled);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_slew_alt_az(int64_t port_,
                                                                                                  struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                  double altitude,
                                                                                                  double azimuth);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_slew_to_coordinates(int64_t port_,
                                                                                                          struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                          double ra,
                                                                                                          double dec);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_sync_to_coordinates(int64_t port_,
                                                                                                          struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                          double ra,
                                                                                                          double dec);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_unpark(int64_t port_,
                                                                                             struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_perform_meridian_flip(int64_t port_,
                                                                                                struct wire_cst_list_prim_u_8_strict *mount_id,
                                                                                                struct wire_cst_list_prim_u_8_strict *camera_id,
                                                                                                struct wire_cst_list_prim_u_8_strict *focuser_id,
                                                                                                struct wire_cst_list_prim_u_8_strict *cover_calibrator_id,
                                                                                                struct wire_cst_list_prim_u_8_strict *target_name,
                                                                                                double target_ra_hours,
                                                                                                double target_dec_degrees,
                                                                                                bool pause_guiding,
                                                                                                bool auto_center,
                                                                                                bool refocus_after,
                                                                                                bool resume_guiding,
                                                                                                double settle_time_secs);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_clear_calibration(int64_t port_,
                                                                                 struct wire_cst_list_prim_u_8_strict *which);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_connect(int64_t port_,
                                                                       struct wire_cst_list_prim_u_8_strict *host,
                                                                       uint16_t *port);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_deselect_star(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_disconnect(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_dither(int64_t port_,
                                                                      double amount,
                                                                      uint8_t ra_only,
                                                                      double settle_pixels,
                                                                      double settle_time,
                                                                      double settle_timeout);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_find_star(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_flip_calibration(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_algo_param(int64_t port_,
                                                                              struct wire_cst_list_prim_u_8_strict *axis,
                                                                              struct wire_cst_list_prim_u_8_strict *name);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_algo_param_names(int64_t port_,
                                                                                    struct wire_cst_list_prim_u_8_strict *axis);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_all_algo_params(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *axis);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_calibration_data(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_exposure(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_lock_position(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_profile(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_star_image(int64_t port_,
                                                                              uint32_t size);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_status(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_loop(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_set_algo_param(int64_t port_,
                                                                              struct wire_cst_list_prim_u_8_strict *axis,
                                                                              struct wire_cst_list_prim_u_8_strict *name,
                                                                              double value);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_set_exposure(int64_t port_,
                                                                            uint32_t exposure_ms);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_set_lock_position(int64_t port_,
                                                                                 double x,
                                                                                 double y,
                                                                                 bool exact);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_set_paused(int64_t port_,
                                                                          bool paused);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_start_guiding(int64_t port_,
                                                                             double settle_pixels,
                                                                             double settle_time,
                                                                             double settle_timeout);

void frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_stop_guiding(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_plan_focuser_backlash_calibration(int64_t port_,
                                                                                               struct wire_cst_list_prim_u_8_strict *config_json,
                                                                                               int32_t center_position);

void frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_plate_solve_blind(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *file_path,
                                                                                   uint32_t *timeout_secs);

void frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_plate_solve_near(int64_t port_,
                                                                                  struct wire_cst_list_prim_u_8_strict *file_path,
                                                                                  double hint_ra,
                                                                                  double hint_dec,
                                                                                  double search_radius,
                                                                                  uint32_t *timeout_secs);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_platesolve_detect(void);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_platesolve_get_config(void);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_platesolve_set_config(struct wire_cst_plate_solver_config_payload *config);

void frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_platesolve_verify(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *executable_path);

void frbgen_nightshade_bridge_wire__crate__api__post_session__entrypoints__api_post_session_cancel(int64_t port_,
                                                                                                   struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_read_fits_file(int64_t port_,
                                                                            struct wire_cst_list_prim_u_8_strict *file_path);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_read_fits_linear_data(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *file_path);

void frbgen_nightshade_bridge_wire__crate__api__init__api_read_log_file(int64_t port_,
                                                                        struct wire_cst_list_prim_u_8_strict *path);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_read_xisf_file(int64_t port_,
                                                                            struct wire_cst_list_prim_u_8_strict *file_path);

void frbgen_nightshade_bridge_wire__crate__api__finishing_enhance__api_reduce_stars_preview(int64_t port_,
                                                                                            struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__hotplug__api_rescan_devices(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__rotator__api_rotator_halt(int64_t port_,
                                                                                               struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__rotator__api_rotator_move_relative(int64_t port_,
                                                                                                        struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                        double delta);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__rotator__api_rotator_move_to(int64_t port_,
                                                                                                  struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                  double angle);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__rotator__api_rotator_set_reverse(int64_t port_,
                                                                                                      struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                      bool reverse);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__rotator__api_rotator_sync_to_pa(int64_t port_,
                                                                                                     struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                     double pa);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_run_autofocus(int64_t port_,
                                                                           struct wire_cst_list_prim_u_8_strict *device_id,
                                                                           struct wire_cst_list_prim_u_8_strict *camera_id,
                                                                           struct wire_cst_autofocus_config_api *config);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_run_focuser_backlash_calibration(int64_t port_,
                                                                                              struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                              struct wire_cst_list_prim_u_8_strict *camera_id,
                                                                                              struct wire_cst_list_prim_u_8_strict *config_json);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_run_indi_autofocus(int64_t port_,
                                                                                struct wire_cst_list_prim_u_8_strict *camera_id,
                                                                                struct wire_cst_list_prim_u_8_strict *focuser_id,
                                                                                struct wire_cst_indi_autofocus_config_api *config);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_fits_file(int64_t port_,
                                                                            struct wire_cst_list_prim_u_8_strict *file_path,
                                                                            uint32_t width,
                                                                            uint32_t height,
                                                                            struct wire_cst_list_prim_u_16_loose *data,
                                                                            struct wire_cst_fits_write_header *header_data);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_fits_from_last_capture(int64_t port_,
                                                                                         struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                         struct wire_cst_list_prim_u_8_strict *file_path,
                                                                                         struct wire_cst_fits_write_header *header_data);

void frbgen_nightshade_bridge_wire__crate__api__post_session__entrypoints__api_save_fits_master(int64_t port_,
                                                                                                struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_jpeg_file(int64_t port_,
                                                                            struct wire_cst_list_prim_u_8_strict *file_path,
                                                                            uint32_t width,
                                                                            uint32_t height,
                                                                            struct wire_cst_list_prim_u_16_loose *data,
                                                                            uint8_t quality);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_png_file(int64_t port_,
                                                                           struct wire_cst_list_prim_u_8_strict *file_path,
                                                                           uint32_t width,
                                                                           uint32_t height,
                                                                           struct wire_cst_list_prim_u_16_loose *data);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__storage__api_save_profile(struct wire_cst_equipment_profile *profile);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_rgba_jpeg_file(int64_t port_,
                                                                                 struct wire_cst_list_prim_u_8_strict *file_path,
                                                                                 uint32_t width,
                                                                                 uint32_t height,
                                                                                 struct wire_cst_list_prim_u_8_loose *rgba,
                                                                                 uint8_t quality);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_rgba_png_file(int64_t port_,
                                                                                struct wire_cst_list_prim_u_8_strict *file_path,
                                                                                uint32_t width,
                                                                                uint32_t height,
                                                                                struct wire_cst_list_prim_u_8_loose *rgba);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_tiff_file(int64_t port_,
                                                                            struct wire_cst_list_prim_u_8_strict *file_path,
                                                                            uint32_t width,
                                                                            uint32_t height,
                                                                            struct wire_cst_list_prim_u_16_loose *data);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_xisf_file(int64_t port_,
                                                                            struct wire_cst_list_prim_u_8_strict *file_path,
                                                                            uint32_t width,
                                                                            uint32_t height,
                                                                            struct wire_cst_list_prim_u_16_loose *data,
                                                                            struct wire_cst_list_record_string_string *properties);

void frbgen_nightshade_bridge_wire__crate__api__secondary_rig__api_secondary_rig_get_status(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__secondary_rig__api_secondary_rig_is_armed(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__secondary_rig__api_secondary_rig_start(int64_t port_,
                                                                                       struct wire_cst_secondary_rig_config_api *config);

void frbgen_nightshade_bridge_wire__crate__api__secondary_rig__api_secondary_rig_stop(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_sequencer_apply_defect_map(int64_t port_,
                                                                                        struct wire_cst_list_prim_u_8_strict *camera_id,
                                                                                        uint32_t width,
                                                                                        uint32_t height,
                                                                                        double sensor_temperature_celsius,
                                                                                        bool enabled,
                                                                                        struct wire_cst_list_prim_u_8_strict *method,
                                                                                        uint8_t kernel_diameter,
                                                                                        bool save_original);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_clear_checkpoint(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_clear_default_adaptive_exposure(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_get_active_sequence_run_id(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_get_adaptive_swap_json(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_get_checkpoint_info(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_get_cloud_motion_json(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_get_current_recovery_json(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_get_decision_logging_enabled(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_get_recovery_history_json(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_get_state(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_has_checkpoint(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_load(int64_t port_,
                                                                                         struct wire_cst_sequence_definition_api *definition);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_load_json(int64_t port_,
                                                                                              struct wire_cst_list_prim_u_8_strict *json);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_pause(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_plugin_node_finished(int64_t port_,
                                                                                                         struct wire_cst_list_prim_u_8_strict *node_id,
                                                                                                         bool success,
                                                                                                         struct wire_cst_list_prim_u_8_strict *message,
                                                                                                         struct wire_cst_list_prim_u_8_strict *structured_detail_json);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_recovery_abort(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_recovery_try_now(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_reset(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_resume(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_resume_from_checkpoint(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_save_checkpoint(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_active_sequence_run_id(int64_t port_,
                                                                                                                    int64_t *sequence_run_id);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_set_checkpoint_dir(int64_t port_,
                                                                                                       struct wire_cst_list_prim_u_8_strict *path);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_decision_logging_enabled(int64_t port_,
                                                                                                                      bool enabled);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_devices(int64_t port_,
                                                                                                     struct wire_cst_list_prim_u_8_strict *camera_id,
                                                                                                     struct wire_cst_list_prim_u_8_strict *mount_id,
                                                                                                     struct wire_cst_list_prim_u_8_strict *focuser_id,
                                                                                                     struct wire_cst_list_prim_u_8_strict *filterwheel_id,
                                                                                                     struct wire_cst_list_prim_u_8_strict *rotator_id,
                                                                                                     struct wire_cst_list_String *filter_names,
                                                                                                     struct wire_cst_list_record_string_i_32 *filter_focus_offsets);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_park_policy(int64_t port_,
                                                                                                         bool park_on_unsafe_weather,
                                                                                                         bool park_before_dawn);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_safety_check_interval_seconds(int64_t port_,
                                                                                                                           uint32_t seconds);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_safety_fail_mode(int64_t port_,
                                                                                                              struct wire_cst_list_prim_u_8_strict *mode);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_save_path(int64_t port_,
                                                                                                       struct wire_cst_list_prim_u_8_strict *path);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_simulation_mode(int64_t port_,
                                                                                                             bool enabled);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_stop_on_quality_problems(int64_t port_,
                                                                                                                      bool stop_on_quality_problems);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_skip(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_skip_to_node(int64_t port_,
                                                                                                 struct wire_cst_list_prim_u_8_strict *node_id);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_start(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_stop(int64_t port_,
                                                                                         struct wire_cst_list_prim_u_8_strict *origin);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__event_bridge__api_sequencer_subscribe_events(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_autofocus_config(int64_t port_,
                                                                                                                 struct wire_cst_list_prim_u_8_strict *config_json);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_autofocus_interval(int64_t port_,
                                                                                                                   uint32_t every_n_frames);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_cloud_motion(int64_t port_,
                                                                                                             double *current_cover_percent,
                                                                                                             double *predicted_arrival_minutes,
                                                                                                             double *predicted_opening_minutes,
                                                                                                             double *predicted_opening_duration_secs,
                                                                                                             double *predicted_clear_sky_alt,
                                                                                                             double *predicted_clear_sky_az);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_conditions_score(int64_t port_,
                                                                                                                 double *score,
                                                                                                                 double *transparency_score,
                                                                                                                 double *seeing_score,
                                                                                                                 double *cloud_score,
                                                                                                                 double *wind_score,
                                                                                                                 double transparency_weight,
                                                                                                                 double seeing_weight,
                                                                                                                 double cloud_weight,
                                                                                                                 double wind_weight,
                                                                                                                 int64_t generated_unix_secs);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_default_adaptive_exposure(int64_t port_,
                                                                                                                          bool enabled,
                                                                                                                          double target_snr,
                                                                                                                          double reference_sky_brightness_mag,
                                                                                                                          double min_exposure_secs,
                                                                                                                          double max_exposure_secs,
                                                                                                                          struct wire_cst_list_String *per_filter_enabled_keys,
                                                                                                                          struct wire_cst_list_bool *per_filter_enabled_values,
                                                                                                                          struct wire_cst_list_String *per_filter_min_keys,
                                                                                                                          struct wire_cst_list_prim_f_64_loose *per_filter_min_values,
                                                                                                                          struct wire_cst_list_String *per_filter_max_keys,
                                                                                                                          struct wire_cst_list_prim_f_64_loose *per_filter_max_values);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_default_quality_check(int64_t port_,
                                                                                                                      double *hfr_threshold,
                                                                                                                      double *hfr_baseline_percent,
                                                                                                                      double *eccentricity_threshold,
                                                                                                                      uint32_t *star_count_min,
                                                                                                                      uint32_t max_consecutive_rejects,
                                                                                                                      bool enabled);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_dither_config(int64_t port_,
                                                                                                              double pixels,
                                                                                                              double settle_pixels,
                                                                                                              double settle_time,
                                                                                                              double settle_timeout,
                                                                                                              bool ra_only);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_filter_offsets(int64_t port_,
                                                                                                               struct wire_cst_list_record_string_i_32 *offsets);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_location(int64_t port_,
                                                                                                         double *latitude,
                                                                                                         double *longitude);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_meridian_flip_config(int64_t port_,
                                                                                                                     struct wire_cst_list_prim_u_8_strict *config_json);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_observer_profile(int64_t port_,
                                                                                                                 struct wire_cst_list_prim_u_8_strict *observer_name,
                                                                                                                 double *site_elevation_m,
                                                                                                                 struct wire_cst_list_prim_u_8_strict *camera_make,
                                                                                                                 struct wire_cst_list_prim_u_8_strict *camera_model,
                                                                                                                 struct wire_cst_list_prim_u_8_strict *telescope_name,
                                                                                                                 double *telescope_focal_length_mm,
                                                                                                                 double *telescope_aperture_mm);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_pending_integration_carry_over(int64_t port_,
                                                                                                                               struct wire_cst_list_record_string_map_string_f_64_none *carry_over);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_recovery_config(int64_t port_,
                                                                                                                struct wire_cst_recovery_config_update *update);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_reject_folder_path(int64_t port_,
                                                                                                                   struct wire_cst_list_prim_u_8_strict *path);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_sky_brightness(int64_t port_,
                                                                                                               double *mag);

void frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_weather_verdict(int64_t port_,
                                                                                                                bool *unsafe_override);

void frbgen_nightshade_bridge_wire__crate__api__devices__camera__api_set_camera_binning(int64_t port_,
                                                                                        struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                        int32_t bin_x,
                                                                                        int32_t bin_y);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__camera__api_set_camera_cooler(int64_t port_,
                                                                                                   struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                   uint8_t enabled,
                                                                                                   double *target_temp);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__camera__api_set_camera_gain(int64_t port_,
                                                                                                 struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                 int32_t gain);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__camera__api_set_camera_offset(int64_t port_,
                                                                                                   struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                   int32_t offset);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__storage__api_set_location(struct wire_cst_observer_location *location);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_set_qhy_discovery_enabled(bool enabled);

void frbgen_nightshade_bridge_wire__crate__api__sky_atlas__api_sky_atlas(int64_t port_,
                                                                         struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__sky_atlas__frames__api_sky_atlas_add_frame(int64_t port_,
                                                                                           struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__sky_atlas__regions__api_sky_atlas_growth(int64_t port_,
                                                                                         struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__sky_atlas__regions__api_sky_atlas_merge_delta(int64_t port_,
                                                                                              struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__sky_atlas__frames__api_sky_atlas_query_cutout(int64_t port_,
                                                                                              struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__sky_atlas__regions__api_sky_atlas_region_info(int64_t port_,
                                                                                              struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_add_frame(int64_t port_,
                                                                                struct wire_cst_list_prim_u_8_strict *image_path);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_add_frame_from_data(int64_t port_,
                                                                                          uint32_t width,
                                                                                          uint32_t height,
                                                                                          struct wire_cst_list_prim_u_16_loose *data);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_frame_count(void);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_get_result(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_get_stats(int64_t port_);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_is_active(void);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_reset(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_save_master_fits(int64_t port_,
                                                                                       struct wire_cst_list_prim_u_8_strict *file_path);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_start(int64_t port_,
                                                                            struct wire_cst_list_prim_u_8_strict *reference_image_path,
                                                                            struct wire_cst_api_live_stacking_config *config);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_start_from_data(int64_t port_,
                                                                                      uint32_t width,
                                                                                      uint32_t height,
                                                                                      struct wire_cst_list_prim_u_16_loose *data,
                                                                                      struct wire_cst_api_live_stacking_config *config);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_stop(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__polar_alignment__entrypoints__api_start_all_sky_polar_alignment(int64_t port_,
                                                                                                                double exposure_time,
                                                                                                                double solve_timeout,
                                                                                                                int32_t binning,
                                                                                                                bool is_north,
                                                                                                                double acceptance_threshold_arcsec,
                                                                                                                double iteration_cadence_secs,
                                                                                                                int32_t *gain,
                                                                                                                int32_t *offset);

void frbgen_nightshade_bridge_wire__crate__api__heartbeat__api_start_device_heartbeat(int64_t port_,
                                                                                      int32_t device_type,
                                                                                      struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                      uint64_t interval_ms);

void frbgen_nightshade_bridge_wire__crate__api__heartbeat__api_start_device_heartbeat_with_config(int64_t port_,
                                                                                                  struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                  uint64_t interval_secs,
                                                                                                  uint32_t failure_threshold,
                                                                                                  bool auto_reconnect,
                                                                                                  uint32_t max_reconnect_attempts);

void frbgen_nightshade_bridge_wire__crate__api__polar_alignment__run_loop__api_start_polar_alignment(int64_t port_,
                                                                                                     double exposure_time,
                                                                                                     double step_size,
                                                                                                     int32_t binning,
                                                                                                     bool is_north,
                                                                                                     bool manual_rotation,
                                                                                                     bool rotate_east,
                                                                                                     int32_t *gain,
                                                                                                     int32_t *offset,
                                                                                                     double *solve_timeout,
                                                                                                     bool *start_from_current,
                                                                                                     double *auto_complete_threshold);

void frbgen_nightshade_bridge_wire__crate__api__session__api_start_session(int64_t port_,
                                                                           struct wire_cst_list_prim_u_8_strict *target_name,
                                                                           double *ra,
                                                                           double *dec);

void frbgen_nightshade_bridge_wire__crate__api__mosaic__api_stitch_mosaic(int64_t port_,
                                                                          struct wire_cst_list_prim_u_8_strict *args_json);

void frbgen_nightshade_bridge_wire__crate__api__heartbeat__api_stop_device_heartbeat(int64_t port_,
                                                                                     struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__polar_alignment__entrypoints__api_stop_polar_alignment(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_can_write(int64_t port_,
                                                                                      struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                      int32_t switch_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_get_description(int64_t port_,
                                                                                            struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                            int32_t switch_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_get_max(int64_t port_,
                                                                                    struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_get_max_value(int64_t port_,
                                                                                          struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                          int32_t switch_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_get_min_value(int64_t port_,
                                                                                          struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                          int32_t switch_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_get_name(int64_t port_,
                                                                                     struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                     int32_t switch_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_get_state(int64_t port_,
                                                                                      struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                      int32_t switch_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_get_value(int64_t port_,
                                                                                      struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                      int32_t switch_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_set_state(int64_t port_,
                                                                                      struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                      int32_t switch_id,
                                                                                      bool state);

void frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_set_value(int64_t port_,
                                                                                      struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                      int32_t switch_id,
                                                                                      double value);

void frbgen_nightshade_bridge_wire__crate__api__imaging__api_update_fits_keywords(int64_t port_,
                                                                                  struct wire_cst_list_prim_u_8_strict *file_path,
                                                                                  struct wire_cst_list_fits_keyword_update *updates);

WireSyncRust2DartDco frbgen_nightshade_bridge_wire__crate__api__storage__api_update_settings(struct wire_cst_app_settings *settings);

void frbgen_nightshade_bridge_wire__crate__api__devices__camera__cancel_exposure(int64_t port_,
                                                                                 struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__connection__alpaca_connections__connect_alpaca_device(int64_t port_,
                                                                                                      int32_t device_type,
                                                                                                      struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__connect_ascom_camera(int64_t port_,
                                                                                                    struct wire_cst_list_prim_u_8_strict *_prog_id);

void frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__connect_ascom_focuser(int64_t port_,
                                                                                                     struct wire_cst_list_prim_u_8_strict *_prog_id);

void frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__connect_ascom_mount(int64_t port_,
                                                                                                   struct wire_cst_list_prim_u_8_strict *_prog_id);

void frbgen_nightshade_bridge_wire__crate__api__connection__alpaca_connections__disconnect_alpaca_device(int64_t port_,
                                                                                                         struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__filter_wheel__filter_wheel_get_config(int64_t port_,
                                                                                               struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__filter_wheel__filter_wheel_get_position(int64_t port_,
                                                                                                 struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__filter_wheel__filter_wheel_set_position(int64_t port_,
                                                                                                 struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                                 int32_t position);

void frbgen_nightshade_bridge_wire__crate__api__imaging__fits_write_header_rich_default(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__devices__focuser__focuser_get_details(int64_t port_,
                                                                                      struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__focuser__focuser_get_position(int64_t port_,
                                                                                       struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__focuser__focuser_get_temp(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__focuser__focuser_halt(int64_t port_,
                                                                               struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__focuser__focuser_move_abs(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                   int32_t position);

void frbgen_nightshade_bridge_wire__crate__api__devices__focuser__focuser_move_rel(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                   int32_t steps);

void frbgen_nightshade_bridge_wire__crate__api__connection__alpaca_connections__get_alpaca_client(int64_t port_,
                                                                                                  struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__get_ascom_camera_temp(int64_t port_,
                                                                                                     struct wire_cst_list_prim_u_8_strict *_prog_id);

void frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__get_ascom_focuser_position(int64_t port_,
                                                                                                          struct wire_cst_list_prim_u_8_strict *_prog_id);

void frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__get_ascom_mount_coords(int64_t port_,
                                                                                                      struct wire_cst_list_prim_u_8_strict *_prog_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__camera__get_camera_status(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__imaging__indi_autofocus_config_api_default(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__connection__alpaca_connections__is_connected(int64_t port_,
                                                                                             struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_abort(int64_t port_,
                                                                            struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_can_park(int64_t port_,
                                                                               struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_find_home(int64_t port_,
                                                                                struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_get_coordinates(int64_t port_,
                                                                                      struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_get_site(int64_t port_,
                                                                               struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_get_status(int64_t port_,
                                                                                 struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_get_time(int64_t port_,
                                                                               struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_get_tracking_rate(int64_t port_,
                                                                                        struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_move_axis(int64_t port_,
                                                                                struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                int32_t axis,
                                                                                double rate);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_park(int64_t port_,
                                                                           struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_pulse_guide(int64_t port_,
                                                                                  struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                  struct wire_cst_list_prim_u_8_strict *direction,
                                                                                  uint32_t duration_ms);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_set_site(int64_t port_,
                                                                               struct wire_cst_list_prim_u_8_strict *device_id,
                                                                               double latitude_deg,
                                                                               double longitude_deg,
                                                                               double *elevation_m);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_set_time(int64_t port_,
                                                                               struct wire_cst_list_prim_u_8_strict *device_id,
                                                                               int64_t utc_unix_seconds,
                                                                               double utc_offset_hours);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_set_tracking(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                   uint8_t enabled);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_set_tracking_rate(int64_t port_,
                                                                                        struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                        int32_t rate);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_site_capabilities(int64_t port_,
                                                                                        struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_slew(int64_t port_,
                                                                           struct wire_cst_list_prim_u_8_strict *device_id,
                                                                           double ra,
                                                                           double dec);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_slew_alt_az(int64_t port_,
                                                                                  struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                  double altitude,
                                                                                  double azimuth);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_stop(int64_t port_,
                                                                           struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_sync(int64_t port_,
                                                                           struct wire_cst_list_prim_u_8_strict *device_id,
                                                                           double ra,
                                                                           double dec);

void frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_unpark(int64_t port_,
                                                                             struct wire_cst_list_prim_u_8_strict *device_id);

void frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__move_ascom_focuser(int64_t port_,
                                                                                                  struct wire_cst_list_prim_u_8_strict *_prog_id,
                                                                                                  int32_t _position);

void frbgen_nightshade_bridge_wire__crate__api__imaging__save_fits_file_rich(int64_t port_,
                                                                             struct wire_cst_list_prim_u_8_strict *file_path,
                                                                             uint32_t width,
                                                                             uint32_t height,
                                                                             struct wire_cst_list_prim_u_16_loose *data,
                                                                             struct wire_cst_fits_write_header_rich *header_data);

void frbgen_nightshade_bridge_wire__crate__api__secondary_rig__secondary_rig_status_api_default(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__devices__camera__set_camera_cooler(int64_t port_,
                                                                                   struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                   uint8_t enabled,
                                                                                   double *target_temp);

void frbgen_nightshade_bridge_wire__crate__api__devices__filter_wheel__set_camera_gain(int64_t port_,
                                                                                       struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                       int32_t gain);

void frbgen_nightshade_bridge_wire__crate__api__devices__filter_wheel__set_camera_offset(int64_t port_,
                                                                                         struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                         int32_t offset);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__camera__simulated_camera_default(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__environment__simulated_dome_default(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__filter_wheel__simulated_filter_wheel_default(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__focuser__simulated_focuser_default(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__simulated_mount_default(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__rotator__simulated_rotator_default(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__environment__simulated_safety_monitor_default(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__devices__simulation__environment__simulated_weather_default(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__slew_ascom_mount(int64_t port_,
                                                                                                struct wire_cst_list_prim_u_8_strict *_prog_id,
                                                                                                double _ra,
                                                                                                double _dec);

void frbgen_nightshade_bridge_wire__crate__api__plate_solve__solve_hints_default(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__imaging__star_detection_config_api_default(int64_t port_);

void frbgen_nightshade_bridge_wire__crate__api__devices__camera__start_exposure(int64_t port_,
                                                                                struct wire_cst_list_prim_u_8_strict *device_id,
                                                                                double duration_secs,
                                                                                int32_t gain,
                                                                                int32_t offset,
                                                                                int32_t bin_x,
                                                                                int32_t bin_y);

void frbgen_nightshade_bridge_rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerArcAlpacaClient(const void *ptr);

void frbgen_nightshade_bridge_rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerArcAlpacaClient(const void *ptr);

void frbgen_nightshade_bridge_rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerDefectMapCorrectionRecord(const void *ptr);

void frbgen_nightshade_bridge_rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerDefectMapCorrectionRecord(const void *ptr);

uintptr_t *frbgen_nightshade_bridge_cst_new_box_autoadd_Auto_Owned_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerArcAlpacaClient(uintptr_t value);

uintptr_t *frbgen_nightshade_bridge_cst_new_box_autoadd_Auto_Owned_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerDefectMapCorrectionRecord(uintptr_t value);

struct wire_cst_api_acquisition_settings *frbgen_nightshade_bridge_cst_new_box_autoadd_api_acquisition_settings(void);

struct wire_cst_api_combine_method *frbgen_nightshade_bridge_cst_new_box_autoadd_api_combine_method(void);

struct wire_cst_api_defect_map_status *frbgen_nightshade_bridge_cst_new_box_autoadd_api_defect_map_status(void);

struct wire_cst_api_depth_forecast *frbgen_nightshade_bridge_cst_new_box_autoadd_api_depth_forecast(void);

struct wire_cst_api_depth_goal_definition *frbgen_nightshade_bridge_cst_new_box_autoadd_api_depth_goal_definition(void);

struct wire_cst_api_depth_measurement *frbgen_nightshade_bridge_cst_new_box_autoadd_api_depth_measurement(void);

struct wire_cst_api_depth_report *frbgen_nightshade_bridge_cst_new_box_autoadd_api_depth_report(void);

struct wire_cst_api_live_stacking_config *frbgen_nightshade_bridge_cst_new_box_autoadd_api_live_stacking_config(void);

struct wire_cst_api_reference_geometry *frbgen_nightshade_bridge_cst_new_box_autoadd_api_reference_geometry(void);

struct wire_cst_app_settings *frbgen_nightshade_bridge_cst_new_box_autoadd_app_settings(void);

struct wire_cst_autofocus_config_api *frbgen_nightshade_bridge_cst_new_box_autoadd_autofocus_config_api(void);

bool *frbgen_nightshade_bridge_cst_new_box_autoadd_bool(bool value);

int32_t *frbgen_nightshade_bridge_cst_new_box_autoadd_calibrator_state(int32_t value);

struct wire_cst_camera_capabilities *frbgen_nightshade_bridge_cst_new_box_autoadd_camera_capabilities(void);

struct wire_cst_checkpoint_info_api *frbgen_nightshade_bridge_cst_new_box_autoadd_checkpoint_info_api(void);

struct wire_cst_cover_calibrator_capabilities *frbgen_nightshade_bridge_cst_new_box_autoadd_cover_calibrator_capabilities(void);

int32_t *frbgen_nightshade_bridge_cst_new_box_autoadd_cover_state(int32_t value);

struct wire_cst_depth_lock_event *frbgen_nightshade_bridge_cst_new_box_autoadd_depth_lock_event(void);

struct wire_cst_dome_capabilities *frbgen_nightshade_bridge_cst_new_box_autoadd_dome_capabilities(void);

struct wire_cst_equipment_event *frbgen_nightshade_bridge_cst_new_box_autoadd_equipment_event(void);

struct wire_cst_equipment_profile *frbgen_nightshade_bridge_cst_new_box_autoadd_equipment_profile(void);

float *frbgen_nightshade_bridge_cst_new_box_autoadd_f_32(float value);

double *frbgen_nightshade_bridge_cst_new_box_autoadd_f_64(double value);

struct wire_cst_filter_wheel_capabilities *frbgen_nightshade_bridge_cst_new_box_autoadd_filter_wheel_capabilities(void);

struct wire_cst_fits_write_header *frbgen_nightshade_bridge_cst_new_box_autoadd_fits_write_header(void);

struct wire_cst_fits_write_header_rich *frbgen_nightshade_bridge_cst_new_box_autoadd_fits_write_header_rich(void);

struct wire_cst_focuser_capabilities *frbgen_nightshade_bridge_cst_new_box_autoadd_focuser_capabilities(void);

struct wire_cst_frame_capture_metadata *frbgen_nightshade_bridge_cst_new_box_autoadd_frame_capture_metadata(void);

struct wire_cst_guiding_event *frbgen_nightshade_bridge_cst_new_box_autoadd_guiding_event(void);

int32_t *frbgen_nightshade_bridge_cst_new_box_autoadd_i_32(int32_t value);

int64_t *frbgen_nightshade_bridge_cst_new_box_autoadd_i_64(int64_t value);

struct wire_cst_imaging_event *frbgen_nightshade_bridge_cst_new_box_autoadd_imaging_event(void);

struct wire_cst_indi_autofocus_config_api *frbgen_nightshade_bridge_cst_new_box_autoadd_indi_autofocus_config_api(void);

struct wire_cst_live_stacking_broadcast_snapshot *frbgen_nightshade_bridge_cst_new_box_autoadd_live_stacking_broadcast_snapshot(void);

struct wire_cst_mount_capabilities *frbgen_nightshade_bridge_cst_new_box_autoadd_mount_capabilities(void);

struct wire_cst_observer_location *frbgen_nightshade_bridge_cst_new_box_autoadd_observer_location(void);

int32_t *frbgen_nightshade_bridge_cst_new_box_autoadd_pier_side(int32_t value);

struct wire_cst_plate_solver_config_payload *frbgen_nightshade_bridge_cst_new_box_autoadd_plate_solver_config_payload(void);

struct wire_cst_polar_alignment_event *frbgen_nightshade_bridge_cst_new_box_autoadd_polar_alignment_event(void);

struct wire_cst_polar_alignment_image_event *frbgen_nightshade_bridge_cst_new_box_autoadd_polar_alignment_image_event(void);

struct wire_cst_polar_alignment_status *frbgen_nightshade_bridge_cst_new_box_autoadd_polar_alignment_status(void);

struct wire_cst_record_f_64_f_64 *frbgen_nightshade_bridge_cst_new_box_autoadd_record_f_64_f_64(void);

struct wire_cst_recovery_config_update *frbgen_nightshade_bridge_cst_new_box_autoadd_recovery_config_update(void);

struct wire_cst_rotator_capabilities *frbgen_nightshade_bridge_cst_new_box_autoadd_rotator_capabilities(void);

struct wire_cst_safety_event *frbgen_nightshade_bridge_cst_new_box_autoadd_safety_event(void);

struct wire_cst_safety_monitor_capabilities *frbgen_nightshade_bridge_cst_new_box_autoadd_safety_monitor_capabilities(void);

struct wire_cst_secondary_rig_config_api *frbgen_nightshade_bridge_cst_new_box_autoadd_secondary_rig_config_api(void);

struct wire_cst_sequence_definition_api *frbgen_nightshade_bridge_cst_new_box_autoadd_sequence_definition_api(void);

struct wire_cst_sequencer_event *frbgen_nightshade_bridge_cst_new_box_autoadd_sequencer_event(void);

int32_t *frbgen_nightshade_bridge_cst_new_box_autoadd_shutter_status(int32_t value);

struct wire_cst_star_detection_config_api *frbgen_nightshade_bridge_cst_new_box_autoadd_star_detection_config_api(void);

struct wire_cst_stretch_params_api *frbgen_nightshade_bridge_cst_new_box_autoadd_stretch_params_api(void);

struct wire_cst_switch_capabilities *frbgen_nightshade_bridge_cst_new_box_autoadd_switch_capabilities(void);

struct wire_cst_system_event *frbgen_nightshade_bridge_cst_new_box_autoadd_system_event(void);

int32_t *frbgen_nightshade_bridge_cst_new_box_autoadd_tracking_rate(int32_t value);

uint16_t *frbgen_nightshade_bridge_cst_new_box_autoadd_u_16(uint16_t value);

uint32_t *frbgen_nightshade_bridge_cst_new_box_autoadd_u_32(uint32_t value);

uint64_t *frbgen_nightshade_bridge_cst_new_box_autoadd_u_64(uint64_t value);

struct wire_cst_weather_capabilities *frbgen_nightshade_bridge_cst_new_box_autoadd_weather_capabilities(void);

struct wire_cst_list_String *frbgen_nightshade_bridge_cst_new_list_String(int32_t len);

struct wire_cst_list_api_depth_curve_point *frbgen_nightshade_bridge_cst_new_list_api_depth_curve_point(int32_t len);

struct wire_cst_list_api_depth_goal *frbgen_nightshade_bridge_cst_new_list_api_depth_goal(int32_t len);

struct wire_cst_list_bool *frbgen_nightshade_bridge_cst_new_list_bool(int32_t len);

struct wire_cst_list_detected_star_info *frbgen_nightshade_bridge_cst_new_list_detected_star_info(int32_t len);

struct wire_cst_list_device_info *frbgen_nightshade_bridge_cst_new_list_device_info(int32_t len);

struct wire_cst_list_equipment_profile *frbgen_nightshade_bridge_cst_new_list_equipment_profile(int32_t len);

struct wire_cst_list_fits_keyword_update *frbgen_nightshade_bridge_cst_new_list_fits_keyword_update(int32_t len);

struct wire_cst_list_focus_data_point *frbgen_nightshade_bridge_cst_new_list_focus_data_point(int32_t len);

struct wire_cst_list_focus_data_point_api *frbgen_nightshade_bridge_cst_new_list_focus_data_point_api(int32_t len);

struct wire_cst_list_mosaic_panel_result *frbgen_nightshade_bridge_cst_new_list_mosaic_panel_result(int32_t len);

struct wire_cst_list_node_definition_api *frbgen_nightshade_bridge_cst_new_list_node_definition_api(int32_t len);

struct wire_cst_list_phd_2_algo_param *frbgen_nightshade_bridge_cst_new_list_phd_2_algo_param(int32_t len);

struct wire_cst_list_prim_f_32_strict *frbgen_nightshade_bridge_cst_new_list_prim_f_32_strict(int32_t len);

struct wire_cst_list_prim_f_64_loose *frbgen_nightshade_bridge_cst_new_list_prim_f_64_loose(int32_t len);

struct wire_cst_list_prim_f_64_strict *frbgen_nightshade_bridge_cst_new_list_prim_f_64_strict(int32_t len);

struct wire_cst_list_prim_i_32_strict *frbgen_nightshade_bridge_cst_new_list_prim_i_32_strict(int32_t len);

struct wire_cst_list_prim_u_16_loose *frbgen_nightshade_bridge_cst_new_list_prim_u_16_loose(int32_t len);

struct wire_cst_list_prim_u_16_strict *frbgen_nightshade_bridge_cst_new_list_prim_u_16_strict(int32_t len);

struct wire_cst_list_prim_u_32_strict *frbgen_nightshade_bridge_cst_new_list_prim_u_32_strict(int32_t len);

struct wire_cst_list_prim_u_8_loose *frbgen_nightshade_bridge_cst_new_list_prim_u_8_loose(int32_t len);

struct wire_cst_list_prim_u_8_strict *frbgen_nightshade_bridge_cst_new_list_prim_u_8_strict(int32_t len);

struct wire_cst_list_quality_tile_metric_api *frbgen_nightshade_bridge_cst_new_list_quality_tile_metric_api(int32_t len);

struct wire_cst_list_quirk_info *frbgen_nightshade_bridge_cst_new_list_quirk_info(int32_t len);

struct wire_cst_list_record_string_f_64 *frbgen_nightshade_bridge_cst_new_list_record_string_f_64(int32_t len);

struct wire_cst_list_record_string_field_availability *frbgen_nightshade_bridge_cst_new_list_record_string_field_availability(int32_t len);

struct wire_cst_list_record_string_i_32 *frbgen_nightshade_bridge_cst_new_list_record_string_i_32(int32_t len);

struct wire_cst_list_record_string_map_string_f_64_none *frbgen_nightshade_bridge_cst_new_list_record_string_map_string_f_64_none(int32_t len);

struct wire_cst_list_record_string_string *frbgen_nightshade_bridge_cst_new_list_record_string_string(int32_t len);

struct wire_cst_list_scheduler_score_entry *frbgen_nightshade_bridge_cst_new_list_scheduler_score_entry(int32_t len);

struct wire_cst_list_star_crop_api *frbgen_nightshade_bridge_cst_new_list_star_crop_api(int32_t len);

struct wire_cst_list_switch_info *frbgen_nightshade_bridge_cst_new_list_switch_info(int32_t len);

struct wire_cst_list_tracking_rate *frbgen_nightshade_bridge_cst_new_list_tracking_rate(int32_t len);
static int64_t dummy_method_to_enforce_bundling(void) {
    int64_t dummy_var = 0;
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_Auto_Owned_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerArcAlpacaClient);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_Auto_Owned_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerDefectMapCorrectionRecord);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_api_acquisition_settings);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_api_combine_method);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_api_defect_map_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_api_depth_forecast);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_api_depth_goal_definition);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_api_depth_measurement);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_api_depth_report);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_api_live_stacking_config);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_api_reference_geometry);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_app_settings);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_autofocus_config_api);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_bool);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_calibrator_state);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_camera_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_checkpoint_info_api);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_cover_calibrator_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_cover_state);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_depth_lock_event);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_dome_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_equipment_event);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_equipment_profile);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_f_32);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_f_64);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_filter_wheel_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_fits_write_header);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_fits_write_header_rich);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_focuser_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_frame_capture_metadata);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_guiding_event);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_i_32);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_i_64);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_imaging_event);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_indi_autofocus_config_api);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_live_stacking_broadcast_snapshot);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_mount_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_observer_location);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_pier_side);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_plate_solver_config_payload);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_polar_alignment_event);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_polar_alignment_image_event);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_polar_alignment_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_record_f_64_f_64);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_recovery_config_update);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_rotator_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_safety_event);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_safety_monitor_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_secondary_rig_config_api);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_sequence_definition_api);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_sequencer_event);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_shutter_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_star_detection_config_api);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_stretch_params_api);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_switch_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_system_event);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_tracking_rate);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_u_16);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_u_32);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_u_64);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_box_autoadd_weather_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_String);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_api_depth_curve_point);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_api_depth_goal);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_bool);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_detected_star_info);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_device_info);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_equipment_profile);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_fits_keyword_update);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_focus_data_point);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_focus_data_point_api);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_mosaic_panel_result);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_node_definition_api);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_phd_2_algo_param);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_prim_f_32_strict);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_prim_f_64_loose);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_prim_f_64_strict);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_prim_i_32_strict);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_prim_u_16_loose);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_prim_u_16_strict);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_prim_u_32_strict);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_prim_u_8_loose);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_prim_u_8_strict);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_quality_tile_metric_api);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_quirk_info);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_record_string_f_64);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_record_string_field_availability);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_record_string_i_32);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_record_string_map_string_f_64_none);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_record_string_string);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_scheduler_score_entry);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_star_crop_api);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_switch_info);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_cst_new_list_tracking_rate);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerArcAlpacaClient);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_rust_arc_decrement_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerDefectMapCorrectionRecord);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerArcAlpacaClient);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_rust_arc_increment_strong_count_RustOpaque_flutter_rust_bridgefor_generatedRustAutoOpaqueInnerDefectMapCorrectionRecord);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__api_invalidate_discovery_cache);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__api_version__api_device_supports_action);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__api_version__api_device_supports_version);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__api_version__api_get_device_api_version);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__alpaca_connections__connect_alpaca_device);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__alpaca_connections__disconnect_alpaca_device);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__alpaca_connections__get_alpaca_client);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__alpaca_connections__is_connected);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__api_connect_device);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__api_disconnect_device);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__api_get_connected_devices);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__api_get_device_display_name);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__api_is_device_connected);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__connect_ascom_camera);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__connect_ascom_focuser);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__connect_ascom_mount);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__get_ascom_camera_temp);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__get_ascom_focuser_position);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__get_ascom_mount_coords);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__move_ascom_focuser);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__connection__ascom_connections__slew_ascom_mount);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__darkroom__entrypoints__api_darkroom_cancel);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__darkroom__entrypoints__api_darkroom_registry);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__darkroom__entrypoints__api_darkroom_render_export);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__darkroom__entrypoints__api_darkroom_render_preview);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__darkroom__entrypoints__api_darkroom_validate);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_check_measurement);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_create_goal);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_get_goal);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_goal_curve);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_ingest_frame);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_inspect_reference);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_list_goals);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_remove_goal);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_replay_goal);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_revise_goal);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_set_goal_preferences);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_sky_rectangle);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__depthlock__api_depthlock_suggest_floor);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__camera__api_camera_capture_preview);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__camera__api_camera_get_recommended_settings);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__camera__api_camera_set_readout_mode);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__camera__api_set_camera_binning);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__camera__cancel_exposure);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__camera__get_camera_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__camera__set_camera_cooler);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__camera__start_exposure);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_calibrator_off);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_calibrator_on);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_close_cover);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_get_brightness);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_get_calibrator_state);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_get_cover_state);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_get_max_brightness);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_get_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_halt_cover);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__cover_calibrator__api_cover_calibrator_open_cover);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_abort_slew);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_close_shutter);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_find_home);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_get_azimuth);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_get_shutter_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_is_slewing);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_open_shutter);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_park);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_set_slaved);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_dome_slew_to_azimuth);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__dome__api_get_dome_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__environment__api_get_safety_monitor_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__environment__api_get_weather_conditions);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__filter_wheel__filter_wheel_get_config);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__filter_wheel__filter_wheel_get_position);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__filter_wheel__filter_wheel_set_position);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__filter_wheel__set_camera_gain);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__filter_wheel__set_camera_offset);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__focuser__focuser_get_details);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__focuser__focuser_get_position);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__focuser__focuser_get_temp);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__focuser__focuser_halt);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__focuser__focuser_move_abs);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__focuser__focuser_move_rel);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_abort);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_can_park);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_find_home);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_get_coordinates);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_get_site);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_get_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_get_time);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_get_tracking_rate);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_move_axis);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_park);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_pulse_guide);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_set_site);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_set_time);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_set_tracking);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_set_tracking_rate);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_site_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_slew);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_slew_alt_az);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_stop);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_sync);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__mount__mount_unpark);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__camera__api_get_camera_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__camera__api_set_camera_cooler);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__camera__api_set_camera_gain);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__camera__api_set_camera_offset);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__camera__simulated_camera_default);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__environment__simulated_dome_default);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__environment__simulated_safety_monitor_default);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__environment__simulated_weather_default);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__filter_wheel__api_filterwheel_get_names);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__filter_wheel__api_filterwheel_set_by_name);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__filter_wheel__api_filterwheel_set_filter_names);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__filter_wheel__api_filterwheel_set_position);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__filter_wheel__api_get_filterwheel_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__filter_wheel__simulated_filter_wheel_default);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__focuser__api_focuser_halt);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__focuser__api_focuser_move_relative);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__focuser__api_focuser_move_to);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__focuser__api_get_focuser_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__focuser__simulated_focuser_default);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_get_mount_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_find_home);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_park);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_pulse_guide);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_set_tracking);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_slew_alt_az);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_slew_to_coordinates);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_sync_to_coordinates);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__api_mount_unpark);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__mount__simulated_mount_default);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__rotator__api_get_rotator_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__rotator__api_rotator_halt);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__rotator__api_rotator_move_relative);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__rotator__api_rotator_move_to);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__rotator__api_rotator_set_reverse);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__rotator__api_rotator_sync_to_pa);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__simulation__rotator__simulated_rotator_default);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_can_write);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_get_description);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_get_max);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_get_max_value);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_get_min_value);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_get_name);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_get_state);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_get_value);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_set_state);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__devices__switch__api_switch_set_value);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_camera_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_cover_calibrator_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_device_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_device_quirks);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_dome_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_filterwheel_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_focuser_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_mount_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_qhy_discovery_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_rotator_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_safety_monitor_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_switch_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_get_weather_capabilities);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_is_qhy_discovery_enabled);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__diagnostics__api_set_qhy_discovery_enabled);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__difference_image__api_difference_image);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__difference_image__api_difference_tile_center);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__discovery__api_discover_alpaca_at_address);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__discovery__api_discover_alpaca_devices);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__discovery__api_discover_devices);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__discovery__api_discover_indi_at_address);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__discovery__api_discover_indi_common_hosts);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__discovery__api_discover_indi_localhost);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__discovery__api_discover_indi_network);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__event_stream__api_event_stream);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__event_stream__api_get_dropped_event_count);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__finishing_analyze__api_analyze_night);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__finishing_analyze__api_color_calibrate);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__finishing_analyze__api_detect_stars_photometry);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__finishing_combine__api_combine_channels);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__finishing_combine__api_drizzle_integrate);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__finishing_enhance__api_deconvolve_preview);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__finishing_enhance__api_extract_background);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__finishing_enhance__api_reduce_stars_preview);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__heartbeat__api_get_device_health);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__heartbeat__api_get_device_heartbeat_info);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__heartbeat__api_get_heartbeat_config_for_type);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__heartbeat__api_is_heartbeat_active);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__heartbeat__api_start_device_heartbeat);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__heartbeat__api_start_device_heartbeat_with_config);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__heartbeat__api_stop_device_heartbeat);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__hotplug__api_rescan_devices);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_apply_stretch);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_auto_stretch_color_image);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_auto_stretch_image);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_calculate_auto_stretch);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_calculate_hfr);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_calculate_histogram);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_calibrate_image_data);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_calibrate_image_file);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_camera_cancel_exposure);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_camera_start_exposure);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_camera_start_exposure_configured);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_cancel_autofocus);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_cancel_focuser_backlash_calibration);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_clear_device_image);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_combine_master_frames);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_compute_fits_quality_maps);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_compute_last_capture_quality_maps);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_debayer_fits_file);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_debayer_image);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_defect_map_apply);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_defect_map_build);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_defect_map_clear);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_defect_map_get_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_detect_stars_in_file);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_generate_filename);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_generate_fits_thumbnail);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_get_image_stats);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_get_last_image);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_get_last_raw_image_data);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_get_next_frame_number);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_get_star_crops_from_last_image);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_live_stacking_config_default);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_plan_focuser_backlash_calibration);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_read_fits_file);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_read_fits_linear_data);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_read_xisf_file);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_run_autofocus);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_run_focuser_backlash_calibration);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_run_indi_autofocus);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_fits_file);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_fits_from_last_capture);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_jpeg_file);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_png_file);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_rgba_jpeg_file);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_rgba_png_file);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_tiff_file);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_save_xisf_file);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_sequencer_apply_defect_map);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_add_frame);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_add_frame_from_data);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_frame_count);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_get_result);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_get_stats);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_is_active);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_reset);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_save_master_fits);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_start);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_start_from_data);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_stacking_stop);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__api_update_fits_keywords);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__fits_write_header_rich_default);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__indi_autofocus_config_api_default);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__save_fits_file_rich);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__imaging__star_detection_config_api_default);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__init__api_export_logs);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__init__api_get_current_log_file);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__init__api_get_log_directory);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__init__api_get_version);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__init__api_init);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__init__api_init_with_logging);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__init__api_list_log_files);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__init__api_read_log_file);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__mosaic__api_stitch_mosaic);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_builtin_guider_get_config);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_builtin_guider_get_tracked_stars_json);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_builtin_guider_set_config);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_deselect_star);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_dither);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_find_star);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_get_calibration);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_get_lock_position);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_get_star_image);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_get_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_loop);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_set_lock_position);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_start_guiding);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_guider_stop);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_is_phd2_running);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_launch_phd2);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_clear_calibration);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_connect);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_deselect_star);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_disconnect);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_dither);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_find_star);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_flip_calibration);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_algo_param);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_algo_param_names);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_all_algo_params);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_calibration_data);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_exposure);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_lock_position);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_profile);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_star_image);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_get_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_loop);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_set_algo_param);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_set_exposure);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_set_lock_position);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_set_paused);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_start_guiding);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__phd2__api_phd2_stop_guiding);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_get_plate_solver_path);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_is_plate_solver_available);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_plate_solve_blind);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_plate_solve_near);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_platesolve_detect);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_platesolve_get_config);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_platesolve_set_config);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__plate_solve__api_platesolve_verify);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__plate_solve__solve_hints_default);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__polar_alignment__entrypoints__api_start_all_sky_polar_alignment);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__polar_alignment__entrypoints__api_stop_polar_alignment);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__polar_alignment__run_loop__api_start_polar_alignment);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__post_session__entrypoints__api_build_master_flat);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__post_session__entrypoints__api_integrate_session);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__post_session__entrypoints__api_master_accumulate);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__post_session__entrypoints__api_post_session_cancel);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__post_session__entrypoints__api_save_fits_master);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__secondary_rig__api_secondary_rig_get_status);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__secondary_rig__api_secondary_rig_is_armed);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__secondary_rig__api_secondary_rig_start);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__secondary_rig__api_secondary_rig_stop);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__secondary_rig__secondary_rig_status_api_default);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__event_bridge__api_sequencer_subscribe_events);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_perform_meridian_flip);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_clear_checkpoint);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_get_checkpoint_info);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_get_state);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_has_checkpoint);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_load);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_load_json);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_pause);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_plugin_node_finished);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_reset);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_resume);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_resume_from_checkpoint);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_save_checkpoint);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_set_checkpoint_dir);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_skip);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_skip_to_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_start);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__lifecycle__api_sequencer_stop);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__mosaic__api_broadcast_deactivate);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__mosaic__api_broadcast_get_active);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__mosaic__api_calculate_altitude);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__mosaic__api_calculate_mosaic_area);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__mosaic__api_calculate_mosaic_panels);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__mosaic__api_estimate_mosaic_time);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_build_sequence);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_autofocus_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_center_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_cool_camera_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_delay_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_dither_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_exposure_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_filter_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_loop_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_notification_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_park_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_rotator_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_script_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_slew_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_target_group_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_target_header_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_unpark_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_wait_time_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__node_factory__api_create_warm_camera_node);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_clear_default_adaptive_exposure);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_get_active_sequence_run_id);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_get_adaptive_swap_json);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_get_cloud_motion_json);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_get_current_recovery_json);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_get_decision_logging_enabled);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_get_recovery_history_json);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_recovery_abort);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_recovery_try_now);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_active_sequence_run_id);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_decision_logging_enabled);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_devices);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_park_policy);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_safety_check_interval_seconds);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_safety_fail_mode);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_save_path);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_simulation_mode);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_set_stop_on_quality_problems);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_autofocus_config);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_autofocus_interval);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_cloud_motion);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_conditions_score);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_default_adaptive_exposure);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_default_quality_check);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_dither_config);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_filter_offsets);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_location);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_meridian_flip_config);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_observer_profile);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_pending_integration_carry_over);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_recovery_config);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_reject_folder_path);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_sky_brightness);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sequencer__runtime_config__api_sequencer_update_weather_verdict);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__session__api_end_session);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__session__api_get_session_state);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__session__api_start_session);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sky_atlas__api_sky_atlas);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sky_atlas__frames__api_sky_atlas_add_frame);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sky_atlas__frames__api_sky_atlas_query_cutout);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sky_atlas__regions__api_sky_atlas_growth);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sky_atlas__regions__api_sky_atlas_merge_delta);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__sky_atlas__regions__api_sky_atlas_region_info);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__storage__api_delete_profile);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__storage__api_get_active_profile);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__storage__api_get_location);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__storage__api_get_profiles);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__storage__api_get_settings);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__storage__api_init_profile_storage);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__storage__api_init_settings_storage);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__storage__api_load_profile);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__storage__api_save_profile);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__storage__api_set_location);
    dummy_var ^= ((int64_t) (void*) frbgen_nightshade_bridge_wire__crate__api__storage__api_update_settings);
    dummy_var ^= ((int64_t) (void*) store_dart_post_cobject);
    return dummy_var;
}
