//! What Skotiq told one mount to do, and so which motion it can explain.

/// A mount command, as the guard needs to know it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum CommandKind {
    /// A goto, a flip or a centering correction.
    Slew,
    Park,
    FindHome,
    /// MoveAxis at a rate in degrees per second; 0 stops the axis.
    MoveAxis {
        axis: i32,
        rate: f64,
    },
    /// AbortSlew or a full stop.
    Abort,
    Sync,
    Unpark,
}

/// How long after a command it may take before the mount shows motion
/// (`Slewing` turning on late, a slow serial link). A window in which the
/// mount never moved closes after this.
const START_GRACE_SECS: f64 = 15.0;

/// How long a mount must read stopped before its commanded move is over.
const SETTLE_SECS: f64 = 3.0;

/// Longest a slew, flip or centering move may run.
const SLEW_CAP_SECS: f64 = 240.0;

/// Longest a park or home may run (the native home timeout is 300 s).
const PARK_HOME_CAP_SECS: f64 = 360.0;

/// A mount slows to a stop after an abort or MoveAxis 0.
const DECEL_SECS: f64 = 5.0;

/// After a sync the reported position jumps; readings in this window are not
/// a jump.
const SYNC_SECS: f64 = 10.0;

/// A park or home reports `AtHome` near its end; that edge is explained for
/// this long after the command.
const HOME_EDGE_SECS: f64 = 600.0;

#[derive(Debug, Clone, Copy)]
struct Window {
    started: f64,
    cap_until: f64,
    seen_moving: bool,
    stopped_since: Option<f64>,
}

/// One mount's commands.
#[derive(Debug, Default)]
pub(crate) struct CommandLedger {
    window: Option<Window>,
    axis_rates: [f64; 2],
    decel_until: f64,
    sync_at: Option<f64>,
    home_or_park_at: Option<f64>,
}

impl CommandLedger {
    /// Record a command sent at `t`.
    pub(crate) fn record(&mut self, t: f64, kind: CommandKind) {
        match kind {
            CommandKind::Slew => self.open(t, SLEW_CAP_SECS),
            CommandKind::Park | CommandKind::FindHome => {
                self.open(t, PARK_HOME_CAP_SECS);
                self.home_or_park_at = Some(t);
            }
            CommandKind::MoveAxis { axis, rate } => {
                let index = usize::from(axis != 0);
                let was_moving = self.axis_rates[index] != 0.0;
                self.axis_rates[index] = if rate.is_finite() { rate } else { 0.0 };
                if was_moving && self.axis_rates[index] == 0.0 {
                    self.decel_until = self.decel_until.max(t + DECEL_SECS);
                }
            }
            CommandKind::Abort => {
                self.window = None;
                self.axis_rates = [0.0; 2];
                self.decel_until = self.decel_until.max(t + DECEL_SECS);
            }
            CommandKind::Sync => self.sync_at = Some(t),
            CommandKind::Unpark => {}
        }
    }

    fn open(&mut self, t: f64, cap: f64) {
        self.window = Some(Window {
            started: t,
            cap_until: t + cap,
            seen_moving: false,
            stopped_since: None,
        });
    }

    /// Feed a reading: `moving` is whether the mount is slewing or its axes
    /// turned faster than tracking since the previous reading. Closes the
    /// commanded move once the mount has settled.
    pub(crate) fn observe(&mut self, t: f64, moving: bool) {
        let Some(window) = self.window.as_mut() else {
            return;
        };
        if t >= window.cap_until {
            self.window = None;
            return;
        }
        if moving {
            window.seen_moving = true;
            window.stopped_since = None;
            return;
        }
        let since = *window.stopped_since.get_or_insert(t);
        let started_or_waited = window.seen_moving || t - window.started >= START_GRACE_SECS;
        if started_or_waited && t - since >= SETTLE_SECS {
            self.window = None;
            self.decel_until = self.decel_until.max(t + 1.0);
        }
    }

    /// Whether a command explains motion at `t`.
    pub(crate) fn expects_motion(&self, t: f64) -> bool {
        self.window.is_some() || self.axis_rates.iter().any(|r| *r != 0.0) || t < self.decel_until
    }

    /// Whether a sync was sent shortly before `t`.
    pub(crate) fn sync_recent(&self, t: f64) -> bool {
        self.sync_at.is_some_and(|at| t - at < SYNC_SECS)
    }

    /// Whether a park or home was sent recently enough to explain `AtHome`.
    pub(crate) fn home_or_park_recent(&self, t: f64) -> bool {
        self.home_or_park_at
            .is_some_and(|at| t - at < HOME_EDGE_SECS)
    }
}
