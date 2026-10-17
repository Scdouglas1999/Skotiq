//! The host-side DepthLock service: a bounded analysis queue over the goal
//! store, the per-frame ingestion pipeline, and the verdict source the
//! executor consults.
//!
//! One worker drains the queue; each job runs on the blocking pool so the
//! numerical work never sits on an async thread. When the queue is full the
//! newest job is shed with an event rather than delaying the capture path
//! that produced it — the frame is already on disk and can be re-ingested.
//! Everything that touches a goal goes through the store's revision checks,
//! so a job that outlives a goal edit commits nothing.

use super::store::{Admission, GoalRecord, GoalStore};
use crate::event::{
    create_event_auto_id, DepthLockEvent, EventCategory, EventPayload, EventSeverity,
    SkotiqEvent,
};
use skotiq_imaging::depthlock::input::{
    self, fnv1a64, AcquisitionSettings, MasterKind, ReferenceGeometry,
};
use skotiq_imaging::depthlock::{
    evaluate, sample_apertures, ApertureFrame, DepthReport, DepthState, ESTIMATOR_VERSION,
};
use skotiq_imaging::registration::{solve_registration, RegistrationConfig, TransformKind};
use skotiq_imaging::{read_fits, ImageData, PixelType};
use skotiq_sequencer::depth_goal::{
    DepthGoalBinding, DepthGoalCompletion, DepthGoalOps, DepthGoalVerdict,
};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::{mpsc, oneshot};

/// Jobs waiting behind the one in flight. Frames arrive one per exposure
/// (tens of seconds apart) and a job takes about a second per goal, so a
/// backlog this deep means analysis is not keeping up and shedding is the
/// right answer.
pub const QUEUE_CAPACITY: usize = 8;

/// Where published events go. Production wires the app event bus; tests
/// collect.
pub type EventSink = Arc<dyn Fn(SkotiqEvent) + Send + Sync>;

/// What became of one frame offered to one goal.
#[derive(Debug, Clone, PartialEq)]
pub enum IngestOutcome {
    /// Became evidence; the goal's analysis was re-run and committed.
    Added { state: DepthState },
    /// Already held under the same stable frame identity.
    Duplicate,
    /// The goal's verdict is already achieved for this revision; intake is
    /// closed until the goal is edited.
    AlreadyAchieved,
    /// Acquired before this revision's selection; discovery data only.
    PreSelection,
    /// Refused, with the ingestion layer's reason. Recorded on the goal.
    Rejected(String),
}

enum Job {
    Frame {
        path: String,
    },
    Ingest {
        goal_id: String,
        path: String,
        reply: oneshot::Sender<Result<IngestOutcome, String>>,
    },
    Replay {
        goal_id: String,
        reply: oneshot::Sender<Result<GoalRecord, String>>,
    },
}

/// Counters for the status surface.
#[derive(Debug, Default)]
pub struct Stats {
    pub queued: AtomicU64,
    pub processed: AtomicU64,
    pub dropped: AtomicU64,
    pub evidence_added: AtomicU64,
    pub evidence_rejected: AtomicU64,
    pub last_frame_ms: AtomicU64,
    pub max_frame_ms: AtomicU64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StatsSnapshot {
    pub queued: u64,
    pub processed: u64,
    pub dropped: u64,
    pub evidence_added: u64,
    pub evidence_rejected: u64,
    pub last_frame_ms: u64,
    pub max_frame_ms: u64,
}

pub struct DepthLockService {
    store: GoalStore,
    jobs: mpsc::Sender<Job>,
    sink: EventSink,
    pub stats: Stats,
}

impl DepthLockService {
    /// Open the store under `root`, repair any analysis a crash left
    /// uncommitted, and start the worker on `runtime`.
    pub fn open(
        root: &Path,
        sink: EventSink,
        runtime: &tokio::runtime::Handle,
    ) -> Result<Arc<Self>, String> {
        let store = GoalStore::open(root)?;
        let (jobs, rx) = mpsc::channel(QUEUE_CAPACITY);
        let service = Arc::new(Self {
            store,
            jobs,
            sink,
            stats: Stats::default(),
        });
        service.repair_uncommitted_analyses();
        // The worker holds only a weak handle: the service owns the queue's
        // sender, so a strong handle here would keep both alive forever and
        // the store's lock with them (a re-open in the same process would
        // then be refused). Dropping the last service handle closes the
        // channel and the worker exits.
        let worker = Arc::downgrade(&service);
        runtime.spawn(async move { Self::run(worker, rx).await });
        Ok(service)
    }

    pub fn store(&self) -> &GoalStore {
        &self.store
    }

    pub fn stats(&self) -> StatsSnapshot {
        StatsSnapshot {
            queued: self.stats.queued.load(Ordering::Relaxed),
            processed: self.stats.processed.load(Ordering::Relaxed),
            dropped: self.stats.dropped.load(Ordering::Relaxed),
            evidence_added: self.stats.evidence_added.load(Ordering::Relaxed),
            evidence_rejected: self.stats.evidence_rejected.load(Ordering::Relaxed),
            last_frame_ms: self.stats.last_frame_ms.load(Ordering::Relaxed),
            max_frame_ms: self.stats.max_frame_ms.load(Ordering::Relaxed),
        }
    }

    /// A crash between `add_evidence` and `commit_analysis` leaves a goal
    /// whose newest evidence has no report. Re-evaluating on open closes
    /// that gap without re-reading any frame; the evidence itself was
    /// committed atomically.
    fn repair_uncommitted_analyses(&self) {
        let Ok(records) = self.store.list() else {
            return;
        };
        for record in records {
            if record.evidence.is_empty()
                || record.analyzed_evidence_revision == Some(record.evidence_revision)
            {
                continue;
            }
            match self.replay_now(&record.id) {
                Ok(_) => tracing::info!(
                    "DepthLock goal {} rev {}: re-evaluated {} frames after an interrupted analysis",
                    record.id,
                    record.revision,
                    record.evidence.len()
                ),
                Err(e) => tracing::warn!(
                    "DepthLock goal {} rev {}: could not re-evaluate after restart: {e}",
                    record.id,
                    record.revision
                ),
            }
        }
    }

    /// Offer a freshly saved light to every applicable goal. Never blocks:
    /// a full queue sheds this frame with an explanation.
    pub fn notify_frame_saved(&self, path: &str) {
        if self.store.list().map(|g| g.is_empty()).unwrap_or(true) {
            return;
        }
        self.enqueue(
            Job::Frame {
                path: path.to_string(),
            },
            path,
        );
    }

    /// Ingest one file for one goal and wait for the outcome. Used for
    /// archival frames and recorded-data replay; the selection timestamp
    /// still applies.
    pub async fn ingest_frame(&self, goal_id: &str, path: &str) -> Result<IngestOutcome, String> {
        let (reply, rx) = oneshot::channel();
        if !self.enqueue(
            Job::Ingest {
                goal_id: goal_id.to_string(),
                path: path.to_string(),
                reply,
            },
            path,
        ) {
            return Err(format!(
                "DepthLock analysis queue is full ({QUEUE_CAPACITY} jobs); try again shortly"
            ));
        }
        rx.await
            .map_err(|_| "DepthLock worker stopped before answering".to_string())?
    }

    /// Re-evaluate a goal over the evidence it already holds.
    pub async fn replay(&self, goal_id: &str) -> Result<GoalRecord, String> {
        let (reply, rx) = oneshot::channel();
        if !self.enqueue(
            Job::Replay {
                goal_id: goal_id.to_string(),
                reply,
            },
            goal_id,
        ) {
            return Err(format!(
                "DepthLock analysis queue is full ({QUEUE_CAPACITY} jobs); try again shortly"
            ));
        }
        rx.await
            .map_err(|_| "DepthLock worker stopped before answering".to_string())?
    }

    fn enqueue(&self, job: Job, source: &str) -> bool {
        match self.jobs.try_send(job) {
            Ok(()) => {
                self.stats.queued.fetch_add(1, Ordering::Relaxed);
                true
            }
            Err(_) => {
                self.stats.dropped.fetch_add(1, Ordering::Relaxed);
                let reason = format!(
                    "DepthLock analysis queue is full ({QUEUE_CAPACITY} jobs); this frame was not \
                     analysed. It is still saved and can be ingested later."
                );
                tracing::warn!("{reason} ({source})");
                self.publish(
                    EventSeverity::Warning,
                    DepthLockEvent::AnalysisDropped {
                        source_path: source.to_string(),
                        reason,
                    },
                );
                false
            }
        }
    }

    async fn run(service: std::sync::Weak<Self>, mut rx: mpsc::Receiver<Job>) {
        while let Some(job) = rx.recv().await {
            let Some(service) = service.upgrade() else {
                return;
            };
            let worker = Arc::clone(&service);
            let result = tokio::task::spawn_blocking(move || worker.process(job)).await;
            service.stats.processed.fetch_add(1, Ordering::Relaxed);
            if let Err(e) = result {
                // A panic inside one job must not take the worker down;
                // the store is poisoned by its own guard if a commit was
                // mid-flight, and the next job sees that.
                tracing::error!("DepthLock analysis job panicked: {e}");
            }
        }
    }

    fn process(&self, job: Job) {
        match job {
            Job::Frame { path } => self.process_saved_frame(&path),
            Job::Ingest {
                goal_id,
                path,
                reply,
            } => {
                let _ = reply.send(self.ingest_now(&goal_id, &path));
            }
            Job::Replay { goal_id, reply } => {
                let _ = reply.send(self.replay_now(&goal_id));
            }
        }
    }

    fn process_saved_frame(&self, path: &str) {
        let goals = match self.store.list() {
            Ok(goals) => goals,
            Err(e) => {
                tracing::warn!("DepthLock: cannot list goals for {path}: {e}");
                return;
            }
        };
        let goals: Vec<GoalRecord> = goals.into_iter().filter(|g| g.definition.enabled).collect();
        if goals.is_empty() {
            return;
        }
        let light = match IngestedLight::read(path) {
            Ok(light) => light,
            Err(e) => {
                // Not a light (a dark, a flat, a colour frame) or unreadable;
                // nothing here is a goal's business, but say so once.
                tracing::debug!("DepthLock: skipping {path}: {e}");
                return;
            }
        };
        for goal in goals {
            let applicable = goal
                .definition
                .acquisition
                .filter
                .eq_ignore_ascii_case(&light.settings.filter)
                && goal
                    .definition
                    .acquisition
                    .instrument
                    .eq_ignore_ascii_case(&light.settings.instrument);
            if !applicable {
                continue;
            }
            let outcome = self.ingest_for_goal(&goal, &light);
            tracing::info!(
                "DepthLock goal {} rev {}: {} -> {:?}",
                goal.id,
                goal.revision,
                path,
                outcome
            );
        }
    }

    /// Synchronous ingestion for one goal; the queue calls this on the
    /// blocking pool and tests call it directly.
    pub fn ingest_now(&self, goal_id: &str, path: &str) -> Result<IngestOutcome, String> {
        let goal = self.store.get(goal_id)?;
        if !goal.definition.enabled {
            return Err(format!("DepthLock goal {goal_id} is disabled"));
        }
        let light = match IngestedLight::read(path) {
            Ok(light) => light,
            Err(reason) => {
                self.reject(&goal, path, &reason);
                return Ok(IngestOutcome::Rejected(reason));
            }
        };
        Ok(self.ingest_for_goal(&goal, &light))
    }

    fn ingest_for_goal(&self, goal: &GoalRecord, light: &IngestedLight) -> IngestOutcome {
        let started = Instant::now();
        let outcome = match self.measure(goal, light) {
            Ok(Some(frame)) => self.admit(goal, frame),
            Ok(None) => IngestOutcome::PreSelection,
            Err(reason) if reason == DUPLICATE => IngestOutcome::Duplicate,
            Err(reason) if reason == ACHIEVED => IngestOutcome::AlreadyAchieved,
            Err(reason) => {
                self.reject(goal, &light.path, &reason);
                IngestOutcome::Rejected(reason)
            }
        };
        let elapsed = started.elapsed().as_millis() as u64;
        self.stats.last_frame_ms.store(elapsed, Ordering::Relaxed);
        self.stats
            .max_frame_ms
            .fetch_max(elapsed, Ordering::Relaxed);
        tracing::debug!(
            "DepthLock goal {} rev {}: measured {} in {elapsed} ms",
            goal.id,
            goal.revision,
            light.path
        );
        outcome
    }

    /// The whole per-frame pipeline: compatibility, provenance, calibration,
    /// masking, registration, aperture sampling. `Ok(None)` is a frame
    /// acquired before this revision's selection.
    fn measure(
        &self,
        goal: &GoalRecord,
        light: &IngestedLight,
    ) -> Result<Option<ApertureFrame>, String> {
        let definition = &goal.definition;
        if goal.evidence.contains_key(&light.identity.frame_id) {
            // Reprocessing or a duplicate event: the first samples stand.
            return Err(DUPLICATE.to_string());
        }
        if goal.analyzed_evidence_revision == Some(goal.evidence_revision)
            && goal
                .report
                .as_ref()
                .is_some_and(|r| r.state == DepthState::Achieved)
        {
            return Err(ACHIEVED.to_string());
        }
        if light.identity.acquired_at_ms <= goal.selected_at_ms {
            return Ok(None);
        }
        input::check_compatible(
            &definition.acquisition,
            &light.settings,
            &definition.compatibility,
        )?;
        if light.image.width != definition.reference.width
            || light.image.height != definition.reference.height
        {
            return Err(format!(
                "Light is {}x{} but the goal's reference is {}x{}",
                light.image.width,
                light.image.height,
                definition.reference.width,
                definition.reference.height
            ));
        }

        let reference = read_reference(&definition.reference_path, &definition.reference)?;
        let (dark, dark_digest) = read_master(
            MasterKind::Dark,
            &definition.dark_path,
            &definition.acquisition,
            &definition.reference,
        )?;
        let (flat, flat_digest) = read_master(
            MasterKind::Flat,
            &definition.flat_path,
            &definition.acquisition,
            &definition.reference,
        )?;
        let digest = provenance_digest(
            &definition.acquisition,
            &definition.reference,
            dark_digest,
            flat_digest,
        );
        if let Some(existing) = goal.evidence.values().next() {
            if existing.provenance_digest != digest {
                return Err(
                    "Calibration context changed since this goal's evidence was gathered (a master \
                     frame or the reference geometry differs). Existing evidence is kept; revise \
                     the goal to start fresh with the new masters."
                        .into(),
                );
            }
        }

        let pixels = input::calibrate_signed(&light.image, &dark, &flat)?;
        let mask = input::source_mask(&light.image)?;
        let config = RegistrationConfig {
            transform_kind: TransformKind::Similarity,
            min_inliers: 8,
            ..RegistrationConfig::default()
        };
        let (transform, stats) = solve_registration(&reference, &light.image, &config)
            .map_err(|e| format!("Could not register this frame to the reference: {e}"))?;
        let wcs = input::registered_wcs(&definition.reference.wcs(), &transform, &stats)?;
        let (signal, background) = sample_apertures(
            &definition.measurement,
            &pixels,
            &mask,
            light.image.width as usize,
            light.image.height as usize,
            &wcs,
        )?;
        Ok(Some(input::aperture_frame(
            light.identity.clone(),
            &light.path,
            &digest,
            signal,
            background,
        )))
    }

    fn admit(&self, goal: &GoalRecord, frame: ApertureFrame) -> IngestOutcome {
        match self.store.add_evidence(&goal.id, goal.revision, frame) {
            Ok(Admission::Added) => {}
            Ok(Admission::Duplicate) => return IngestOutcome::Duplicate,
            Ok(Admission::AlreadyAchieved) => return IngestOutcome::AlreadyAchieved,
            Err(reason) => {
                // The store refused (revision moved, disabled, poisoned):
                // nothing to record against the goal itself.
                tracing::warn!("DepthLock goal {}: evidence not stored: {reason}", goal.id);
                return IngestOutcome::Rejected(reason);
            }
        }
        self.stats.evidence_added.fetch_add(1, Ordering::Relaxed);
        match self.replay_now(&goal.id) {
            Ok(record) => IngestOutcome::Added {
                state: record
                    .report
                    .as_ref()
                    .map(|r| r.state.clone())
                    .unwrap_or(DepthState::InsufficientEvidence),
            },
            Err(reason) => {
                tracing::warn!(
                    "DepthLock goal {}: analysis not committed: {reason}",
                    goal.id
                );
                IngestOutcome::Rejected(reason)
            }
        }
    }

    /// Evaluate the goal's current evidence and commit the result against
    /// the revision and evidence revision it was computed for.
    pub fn replay_now(&self, goal_id: &str) -> Result<GoalRecord, String> {
        let record = self.store.get(goal_id)?;
        let evidence: Vec<ApertureFrame> = record.evidence.values().cloned().collect();
        let (report, candidate) = evaluate(
            &record.definition.measurement,
            &evidence,
            record.selected_at_ms,
            record.candidate.as_ref(),
        );
        self.store.commit_analysis(
            goal_id,
            record.revision,
            record.evidence_revision,
            report.clone(),
            candidate,
        )?;
        let committed = self.store.get(goal_id)?;
        self.publish_report(&committed, &report);
        Ok(committed)
    }

    fn reject(&self, goal: &GoalRecord, path: &str, reason: &str) {
        self.stats.evidence_rejected.fetch_add(1, Ordering::Relaxed);
        if let Err(e) = self
            .store
            .record_issue(&goal.id, goal.revision, reason.to_string())
        {
            tracing::debug!("DepthLock goal {}: issue not recorded: {e}", goal.id);
        }
        self.publish(
            EventSeverity::Warning,
            DepthLockEvent::EvidenceRejected {
                goal_id: goal.id.clone(),
                revision: goal.revision,
                source_path: path.to_string(),
                reason: reason.to_string(),
            },
        );
    }

    fn publish_report(&self, record: &GoalRecord, report: &DepthReport) {
        self.publish(
            EventSeverity::Info,
            DepthLockEvent::GoalUpdated {
                goal_id: record.id.clone(),
                revision: record.revision,
                filter_name: record.definition.filter_name.clone(),
                state: state_label(&report.state).to_string(),
                score: report.score,
                conservative_score: report.conservative_score,
                threshold: record.definition.measurement.threshold,
                uncertainty_adu: report.uncertainty_adu,
                coverage: report.coverage,
                evidence_frames: report.evidence_frames as u32,
                confirmation_frames: report.confirmation_frames as u32,
                reason: report.reason.clone(),
                automatic_completion: record.definition.automatic_completion,
                frames_remaining: report.forecast.as_ref().and_then(|f| {
                    f.reachable
                        .then(|| (f.frames_to_threshold + f.frames_to_confirm) as u32)
                }),
                reachable: report.forecast.as_ref().is_none_or(|f| f.reachable),
            },
        );
    }

    pub fn publish_change(&self, goal_id: &str, revision: u64, change: &str) {
        self.publish(
            EventSeverity::Info,
            DepthLockEvent::GoalChanged {
                goal_id: goal_id.to_string(),
                revision,
                change: change.to_string(),
            },
        );
    }

    fn publish(&self, severity: EventSeverity, event: DepthLockEvent) {
        (self.sink)(create_event_auto_id(
            severity,
            EventCategory::Imaging,
            EventPayload::DepthLock(event),
        ));
    }
}

/// Sentinel reasons for the refusals that are not issues: a frame the goal
/// already holds, and a goal whose verdict is already final.
const DUPLICATE: &str = "duplicate";
const ACHIEVED: &str = "achieved";

pub fn state_label(state: &DepthState) -> &'static str {
    match state {
        DepthState::InsufficientEvidence => "insufficientEvidence",
        DepthState::Collecting => "collecting",
        DepthState::ConfirmationPending => "confirmationPending",
        DepthState::Achieved => "achieved",
        DepthState::Unreliable => "unreliable",
    }
}

impl DepthGoalOps for DepthLockService {
    fn verdict(&self, binding: &DepthGoalBinding) -> DepthGoalVerdict {
        let record = match self.store.get(&binding.goal_id) {
            Ok(record) => record,
            Err(reason) => return DepthGoalVerdict::Unavailable { reason },
        };
        if record.revision != binding.revision {
            return DepthGoalVerdict::Unavailable {
                reason: format!(
                    "the goal is at revision {} but the plan is bound to revision {}; rebind the \
                     plan to the current definition",
                    record.revision, binding.revision
                ),
            };
        }
        let definition = &record.definition;
        if !definition.enabled {
            return DepthGoalVerdict::Continue {
                reason: "goal is disabled".into(),
            };
        }
        if !definition.automatic_completion {
            return DepthGoalVerdict::Continue {
                reason: "automatic completion is off; the goal is advisory".into(),
            };
        }
        let Some(report) = &record.report else {
            return DepthGoalVerdict::Continue {
                reason: "no analysis committed yet".into(),
            };
        };
        if record.analyzed_evidence_revision != Some(record.evidence_revision) {
            return DepthGoalVerdict::Continue {
                reason: "analysis of the latest evidence is still pending".into(),
            };
        }
        if report.state != DepthState::Achieved {
            return DepthGoalVerdict::Continue {
                reason: report.reason.clone(),
            };
        }
        DepthGoalVerdict::Achieved(DepthGoalCompletion {
            goal_id: record.id.clone(),
            revision: record.revision,
            evidence_frames: report.evidence_frames as u32,
            confirmation_frames: report.confirmation_frames as u32,
            score: report.score.unwrap_or(f64::NAN),
            threshold: definition.measurement.threshold,
        })
    }
}

/// A light read from disk with everything ingestion needs to know about it.
pub struct IngestedLight {
    pub path: String,
    pub image: ImageData,
    pub settings: AcquisitionSettings,
    pub identity: input::LightIdentity,
}

impl IngestedLight {
    pub fn read(path: &str) -> Result<Self, String> {
        let (image, header) =
            read_fits(Path::new(path)).map_err(|e| format!("Cannot read {path}: {e}"))?;
        let settings = input::light_settings(&header)?;
        if image.pixel_type != PixelType::U16 || image.channels != 1 {
            return Err("DepthLock lights must be unprocessed monochrome 16-bit frames".into());
        }
        let identity = input::light_identity(&header, &image)?;
        Ok(Self {
            path: path.to_string(),
            image,
            settings,
            identity,
        })
    }
}

fn read_reference(path: &str, geometry: &ReferenceGeometry) -> Result<ImageData, String> {
    let (image, _) = read_fits(Path::new(path))
        .map_err(|e| format!("Cannot read the goal's reference frame {path}: {e}"))?;
    if image.pixel_type != PixelType::U16 || image.channels != 1 {
        return Err("The goal's reference frame must be a monochrome 16-bit light".into());
    }
    if image.width != geometry.width || image.height != geometry.height {
        return Err(format!(
            "The reference frame on disk is {}x{} but the goal froze {}x{}; the file changed",
            image.width, image.height, geometry.width, geometry.height
        ));
    }
    Ok(image)
}

fn read_master(
    kind: MasterKind,
    path: &str,
    acquisition: &AcquisitionSettings,
    reference: &ReferenceGeometry,
) -> Result<(ImageData, u64), String> {
    let (image, header) = read_fits(Path::new(path)).map_err(|e| {
        format!(
            "Cannot read the goal's master {}: {e}",
            match kind {
                MasterKind::Dark => "dark",
                MasterKind::Flat => "flat",
            }
        )
    })?;
    input::validate_master(kind, &header, &image, acquisition, reference)?;
    let digest = fnv1a64(image.data.iter().copied());
    Ok((image, digest))
}

/// Everything that must be identical for two exposures' apertures to be
/// pooled: the estimator version, the acquisition the goal was defined for,
/// the reference geometry, and the exact master pixels.
fn provenance_digest(
    acquisition: &AcquisitionSettings,
    reference: &ReferenceGeometry,
    dark_digest: u64,
    flat_digest: u64,
) -> String {
    let mut bytes = Vec::new();
    bytes.extend_from_slice(&ESTIMATOR_VERSION.to_le_bytes());
    bytes.extend_from_slice(acquisition.instrument.to_ascii_lowercase().as_bytes());
    bytes.push(0);
    bytes.extend_from_slice(acquisition.filter.to_ascii_lowercase().as_bytes());
    bytes.push(0);
    bytes.extend_from_slice(&acquisition.exposure_secs.to_bits().to_le_bytes());
    for value in [acquisition.gain, acquisition.offset] {
        bytes.extend_from_slice(&value.unwrap_or(i32::MIN).to_le_bytes());
    }
    bytes.extend_from_slice(&acquisition.bin_x.to_le_bytes());
    bytes.extend_from_slice(&acquisition.bin_y.to_le_bytes());
    for value in [
        reference.crval1,
        reference.crval2,
        reference.crpix1,
        reference.crpix2,
        reference.cd1_1,
        reference.cd1_2,
        reference.cd2_1,
        reference.cd2_2,
    ] {
        bytes.extend_from_slice(&value.to_bits().to_le_bytes());
    }
    bytes.extend_from_slice(&reference.width.to_le_bytes());
    bytes.extend_from_slice(&reference.height.to_le_bytes());
    bytes.extend_from_slice(&dark_digest.to_le_bytes());
    bytes.extend_from_slice(&flat_digest.to_le_bytes());
    format!("v{ESTIMATOR_VERSION}:{:016x}", fnv1a64(bytes))
}
