import 'package:flutter/widgets.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// The canonical semantic icon surface for Skotiq.
///
/// Lucide is the convention: one coherent line-icon family rather than a mix of
/// two visual languages. Every icon has a *role-based* name (e.g. [camera],
/// [warning], [refresh]) backed by the chosen Lucide glyph, so the intent —
/// not an arbitrary glyph choice — lives at the call site.
///
/// ## Conventions
///
/// - Every value is a Lucide [IconData] (the go-forward family). Where a
///   Material icon in the screens has no clean Lucide equivalent, the migration
///   map (`docs/design/overhaul/archive/icon-migration-map.md`) flags it to KEEP
///   Material rather than pick a misleading glyph — those are intentionally
///   absent here.
/// - Names are *semantic* (the thing the icon means), not glyph names. Prefer
///   [delete] over `trash2`, [error] over `xCircle`. A few low-level glyph-named
///   members (e.g. [circle], [square], [dot]) are kept where the icon genuinely
///   is a primitive shape used as a status/marker token.
/// - This is a stable surface. Re-point a member at a different Lucide glyph
///   only as a deliberate, reviewed design change (it shifts every adopting
///   call site at once — that is the point).
abstract final class SkotiqIcons {
  SkotiqIcons._();

  // Devices / equipment

  /// Imaging / guide camera.
  static const IconData camera = LucideIcons.camera;

  /// Camera in a disconnected / no-signal state.
  static const IconData cameraOff = LucideIcons.cameraOff;

  /// Telescope mount.
  ///
  /// Lucide has no telescope glyph in this version; [mountain] reads as the
  /// "mount" silhouette already used across the equipment screens.
  static const IconData mount = LucideIcons.mountain;

  /// Focuser (drawtube / focus motor).
  static const IconData focuser = LucideIcons.focus;

  /// Filter wheel.
  static const IconData filterWheel = LucideIcons.disc;

  /// Active optical filter (selection / filter state, distinct from the wheel).
  static const IconData filter = LucideIcons.filter;

  /// Autoguider.
  static const IconData guider = LucideIcons.crosshair;

  /// Field rotator.
  static const IconData rotator = LucideIcons.rotateCw;

  /// Observatory dome / roll-off roof.
  static const IconData dome = LucideIcons.warehouse;

  /// Telescope dust / flat cover (open state).
  static const IconData cover = LucideIcons.doorOpen;

  /// Telescope cover, closed state.
  static const IconData coverClosed = LucideIcons.doorClosed;

  /// Switch / power-control device.
  // ignore: constant_identifier_names — `switch` is a reserved word.
  static const IconData switch_ = LucideIcons.toggleLeft;

  /// Power / on-off control.
  static const IconData power = LucideIcons.power;

  /// Optics aperture (lens / OTA).
  static const IconData aperture = LucideIcons.aperture;

  /// Generic connected device / host machine.
  static const IconData device = LucideIcons.monitor;

  /// Phone / mobile companion.
  static const IconData phone = LucideIcons.smartphone;

  // Domain

  /// Imaging target / object of interest.
  static const IconData target = LucideIcons.target;

  /// Precise centering / plate-solve crosshair reticle.
  static const IconData crosshair = LucideIcons.crosshair;

  /// Sky compass / orientation.
  static const IconData compass = LucideIcons.compass;

  /// Catalog / favourite object.
  static const IconData star = LucideIcons.star;

  /// Framing / field-of-view frame.
  static const IconData frame = LucideIcons.frame;

  /// Angular measurement / ruler.
  static const IconData ruler = LucideIcons.ruler;

  /// Geographic / sky location pin.
  static const IconData location = LucideIcons.mapPin;

  /// Map / sky chart.
  static const IconData map = LucideIcons.map;

  /// Globe / site / world position.
  static const IconData globe = LucideIcons.globe;

  /// Science / measurement (photometry, analysis).
  static const IconData science = LucideIcons.flaskConical;

  // Run / transport controls

  /// Start / run / play.
  static const IconData play = LucideIcons.play;

  /// Pause.
  static const IconData pause = LucideIcons.pause;

  /// Stop / abort.
  static const IconData stop = LucideIcons.square;

  /// Stop, circular badge variant (e.g. abort-with-confirm).
  static const IconData stopCircle = LucideIcons.stopCircle;

  /// Skip / advance to next.
  static const IconData skip = LucideIcons.skipForward;

  /// Loop / repeat.
  static const IconData repeat = LucideIcons.repeat;

  // Status

  /// Warning — recoverable / attention-needed condition.
  static const IconData warning = LucideIcons.alertTriangle;

  /// Error — failed / blocking condition.
  static const IconData error = LucideIcons.xCircle;

  /// Critical / severe error (octagon "stop" emphasis).
  static const IconData critical = LucideIcons.alertOctagon;

  /// Success / completed OK.
  static const IconData success = LucideIcons.checkCircle;

  /// Informational note.
  static const IconData info = LucideIcons.info;

  /// Help / unknown / question.
  static const IconData help = LucideIcons.helpCircle;

  /// Plain affirmative check (no badge).
  static const IconData check = LucideIcons.check;

  /// Live activity / heartbeat.
  static const IconData activity = LucideIcons.activity;

  /// Generic in-progress spinner.
  static const IconData loading = LucideIcons.loader2;

  /// Status marker dot / ring (primitive).
  static const IconData circle = LucideIcons.circle;

  /// Filled status disc (primitive).
  static const IconData dot = LucideIcons.circleDot;

  // Actions

  /// Add / create new.
  static const IconData add = LucideIcons.plus;

  /// Remove / subtract (inline, non-destructive).
  static const IconData remove = LucideIcons.minus;

  /// Delete / destroy.
  static const IconData delete = LucideIcons.trash2;

  /// Edit / rename.
  static const IconData edit = LucideIcons.pencil;

  /// Copy / duplicate.
  static const IconData copy = LucideIcons.copy;

  /// Save / persist.
  static const IconData save = LucideIcons.save;

  /// Refresh / rescan / reload.
  static const IconData refresh = LucideIcons.refreshCw;

  /// Undo / revert (counter-clockwise).
  static const IconData undo = LucideIcons.rotateCcw;

  /// Search / find.
  static const IconData search = LucideIcons.search;

  /// Search-with-no-result.
  static const IconData searchEmpty = LucideIcons.searchX;

  /// Close / dismiss.
  static const IconData close = LucideIcons.x;

  /// Download / import.
  static const IconData download = LucideIcons.download;

  /// Upload / export.
  static const IconData upload = LucideIcons.upload;

  /// Send / submit.
  static const IconData send = LucideIcons.send;

  /// Share.
  static const IconData share = LucideIcons.share2;

  /// External link / open elsewhere.
  static const IconData externalLink = LucideIcons.externalLink;

  /// Hyperlink / connection between items.
  static const IconData link = LucideIcons.link;

  /// Overflow / more actions.
  static const IconData more = LucideIcons.moreVertical;

  /// Expand to full size.
  static const IconData expand = LucideIcons.maximize2;

  /// Collapse to small size.
  static const IconData collapse = LucideIcons.minimize2;

  // Navigation / disclosure

  static const IconData chevronDown = LucideIcons.chevronDown;
  static const IconData chevronUp = LucideIcons.chevronUp;
  static const IconData chevronLeft = LucideIcons.chevronLeft;
  static const IconData chevronRight = LucideIcons.chevronRight;
  static const IconData arrowUp = LucideIcons.arrowUp;
  static const IconData arrowDown = LucideIcons.arrowDown;
  static const IconData arrowLeft = LucideIcons.arrowLeft;
  static const IconData arrowRight = LucideIcons.arrowRight;

  /// Home / dashboard.
  static const IconData home = LucideIcons.home;

  /// Move / drag handle.
  static const IconData move = LucideIcons.move;

  // Structure / layout

  /// List view.
  static const IconData list = LucideIcons.list;

  /// Ordered / numbered list (e.g. sequence steps).
  static const IconData listOrdered = LucideIcons.listOrdered;

  /// Checklist.
  static const IconData checklist = LucideIcons.listChecks;

  /// Grid view.
  static const IconData grid = LucideIcons.grid;

  /// Dashboard / tile layout.
  static const IconData layoutGrid = LucideIcons.layoutGrid;

  /// Stacked layers (e.g. integration stack, overlays).
  static const IconData layers = LucideIcons.layers;

  /// Folder.
  static const IconData folder = LucideIcons.folder;

  /// Open folder / browse.
  static const IconData folderOpen = LucideIcons.folderOpen;

  /// Document / log file.
  static const IconData file = LucideIcons.fileText;

  // Settings / tuning

  /// Settings / preferences.
  static const IconData settings = LucideIcons.settings;

  /// Advanced / secondary settings.
  static const IconData settings2 = LucideIcons.settings2;

  /// Sliders / parameter tuning.
  static const IconData sliders = LucideIcons.sliders;

  /// Tools / wrench.
  static const IconData tools = LucideIcons.wrench;

  /// Tunable AI / brain (autoguider brain, smart features).
  static const IconData brain = LucideIcons.brain;

  // Time / scheduling

  /// Clock / time-of-day.
  static const IconData clock = LucideIcons.clock;

  /// Countdown / duration timer.
  static const IconData timer = LucideIcons.timer;

  /// History / past runs.
  static const IconData history = LucideIcons.history;

  /// Calendar / scheduling.
  static const IconData calendar = LucideIcons.calendar;

  // Weather / sky conditions

  /// General weather / sky conditions.
  static const IconData weather = LucideIcons.cloudSun;

  /// Cloud cover.
  static const IconData cloud = LucideIcons.cloud;

  /// Rain / precipitation.
  static const IconData rain = LucideIcons.cloudRain;

  /// Sun / daytime.
  static const IconData sun = LucideIcons.sun;

  /// Sunrise / dawn.
  static const IconData sunrise = LucideIcons.sunrise;

  /// Sunset / dusk.
  static const IconData sunset = LucideIcons.sunset;

  /// Moon / night / lunar phase.
  static const IconData moon = LucideIcons.moon;

  /// Wind.
  static const IconData wind = LucideIcons.wind;

  /// Frost / freezing.
  static const IconData frost = LucideIcons.snowflake;

  /// Temperature.
  static const IconData temperature = LucideIcons.thermometer;

  /// Humidity / dew.
  static const IconData humidity = LucideIcons.droplets;

  // Data / system

  /// Disk / local storage.
  static const IconData disk = LucideIcons.hardDrive;

  /// Database.
  static const IconData database = LucideIcons.database;

  /// Server / remote host.
  static const IconData server = LucideIcons.server;

  /// CPU / compute.
  static const IconData cpu = LucideIcons.cpu;

  /// Network / connectivity.
  static const IconData network = LucideIcons.wifi;

  /// Connected plug (device link up).
  static const IconData connected = LucideIcons.plug;

  /// Disconnected plug (device link down).
  static const IconData disconnected = LucideIcons.unplug;

  /// Measurement gauge / dial.
  static const IconData gauge = LucideIcons.gauge;

  /// Trend line / chart.
  static const IconData chart = LucideIcons.lineChart;

  // Visibility / notifications / security

  /// Visible / shown.
  static const IconData visible = LucideIcons.eye;

  /// Hidden.
  static const IconData hidden = LucideIcons.eyeOff;

  /// Notifications / alerts bell.
  static const IconData notifications = LucideIcons.bell;

  /// Notifications muted.
  static const IconData notificationsOff = LucideIcons.bellOff;

  /// Verified / protected.
  static const IconData shieldOk = LucideIcons.shieldCheck;

  /// Security warning.
  static const IconData shieldAlert = LucideIcons.shieldAlert;

  /// Protection switched off / not being monitored. Use instead of [shieldOk]
  /// whenever a check is disabled: a green "verified" shield over an unchecked
  /// subsystem tells the operator they are protected when they are not.
  static const IconData shieldOff = LucideIcons.shieldOff;

  /// Locked.
  static const IconData lock = LucideIcons.lock;

  /// Unlocked.
  static const IconData unlock = LucideIcons.unlock;

  /// Credential / key.
  static const IconData key = LucideIcons.key;

  /// User / account.
  static const IconData user = LucideIcons.user;

  // Imaging / misc

  /// Image / captured frame.
  static const IconData image = LucideIcons.image;

  /// Missing / broken image.
  static const IconData imageOff = LucideIcons.imageOff;

  /// Energy / fast / auto action.
  static const IconData bolt = LucideIcons.zap;

  /// Highlight / smart / AI-assisted.
  static const IconData sparkle = LucideIcons.sparkles;

  /// Idea / tip.
  static const IconData idea = LucideIcons.lightbulb;

  /// Documentation / guide.
  static const IconData book = LucideIcons.bookOpen;

  /// Plugin / extension.
  static const IconData plugin = LucideIcons.puzzle;

  /// Tag / label.
  static const IconData tag = LucideIcons.tag;

  /// Theme / appearance.
  static const IconData palette = LucideIcons.palette;
}
