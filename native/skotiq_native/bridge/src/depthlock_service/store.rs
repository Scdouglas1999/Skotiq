//! Durable DepthLock goals and their evidence.
//!
//! One JSON record per goal under the settings directory, written with a
//! pending-file rename so a crash never leaves a half-written record, and a
//! process-wide lock file so two hosts cannot write the same store. Every
//! mutation is checked against the caller's expected revision (and, for
//! analysis, evidence revision) so a late worker cannot commit against a
//! goal the user has since redefined. A failed commit poisons the store
//! until restart rather than letting memory and disk disagree.

use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use skotiq_imaging::depthlock::input::{
    AcquisitionSettings, CompatibilityPolicy, ReferenceGeometry,
};
use skotiq_imaging::depthlock::{
    ApertureFrame, Candidate, DepthReport, DepthState, MeasurementSpec, CONFIRMATION_FRAMES,
};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

const SCHEMA_VERSION: u32 = 1;
const MAX_FIELD_CHARS: usize = 4096;
const MAX_GOALS: usize = 16;
const MAX_EVIDENCE_PER_GOAL: usize = 4096;
const MAX_RECORD_BYTES: u64 = 128 * 1024 * 1024;
const POISONED: &str = "DepthLock storage requires restart after a failed commit";

/// What a goal is, independent of any evidence gathered for it. Changing any
/// field except the two preferences at the end is a new revision.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GoalDefinition {
    /// Operator-facing name; may be empty.
    pub label: String,
    /// Grouping identities from the host's records, kept as strings so the
    /// store does not depend on the host's schema; empty when the host has
    /// no active project, target or profile.
    pub project_id: String,
    pub target_id: String,
    pub profile_id: String,
    /// The filter this goal measures; one goal never speaks for another
    /// channel.
    pub filter_name: String,
    /// 0-based wheel slot when the host knows it.
    pub filter_index: Option<i32>,
    /// The frame the region was selected on, and its frozen geometry.
    pub reference_path: String,
    pub reference: ReferenceGeometry,
    /// The acquisition every contributing light must match, and how closely.
    pub acquisition: AcquisitionSettings,
    pub compatibility: CompatibilityPolicy,
    /// Master frames the calibration library matched to that acquisition.
    pub dark_path: String,
    pub flat_path: String,
    pub measurement: MeasurementSpec,
    /// Ingestion and analysis run only while enabled.
    pub enabled: bool,
    /// Whether an achieved verdict may complete a bound Smart Exposure plan.
    /// Off by default: advisory only.
    pub automatic_completion: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ArchivedRevision {
    pub revision: u64,
    pub definition: GoalDefinition,
    pub selected_at_ms: i64,
    pub evidence: Vec<EvidenceReference>,
    pub report: Option<DepthReport>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EvidenceReference {
    pub frame_id: String,
    pub source_path: String,
    pub provenance_digest: String,
}

impl EvidenceReference {
    fn from_frame(frame: &ApertureFrame) -> Self {
        Self {
            frame_id: frame.frame_id.clone(),
            source_path: frame.source_path.clone(),
            provenance_digest: frame.provenance_digest.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GoalRecord {
    pub schema_version: u32,
    pub id: String,
    pub revision: u64,
    pub definition: GoalDefinition,
    pub selected_at_ms: i64,
    pub evidence_revision: u64,
    pub evidence: BTreeMap<String, ApertureFrame>,
    pub analyzed_evidence_revision: Option<u64>,
    pub report: Option<DepthReport>,
    pub candidate: Option<Candidate>,
    pub deleted: bool,
    pub last_issue: Option<String>,
    pub history: Vec<ArchivedRevision>,
}

fn checked_field(name: &str, value: &str) -> Result<(), String> {
    if value.trim().is_empty() {
        return Err(format!("{name} must not be empty"));
    }
    if value.chars().count() > MAX_FIELD_CHARS {
        return Err(format!("{name} exceeds {MAX_FIELD_CHARS} characters"));
    }
    Ok(())
}

impl GoalDefinition {
    pub fn validate(&self) -> Result<(), String> {
        self.measurement.validate()?;
        self.reference.validate()?;
        if self.label.chars().count() > MAX_FIELD_CHARS {
            return Err(format!("label exceeds {MAX_FIELD_CHARS} characters"));
        }
        // Project, target and profile are grouping identities the host
        // supplies when it has them; a goal's own identity is its id,
        // filter and provenance, so none of the three is required.
        for (name, value) in [
            ("filterName", self.filter_name.as_str()),
            ("referencePath", self.reference_path.as_str()),
            ("darkPath", self.dark_path.as_str()),
            ("flatPath", self.flat_path.as_str()),
            (
                "acquisition.instrument",
                self.acquisition.instrument.as_str(),
            ),
            ("acquisition.filter", self.acquisition.filter.as_str()),
        ] {
            checked_field(name, value)?;
        }
        if !self
            .acquisition
            .filter
            .eq_ignore_ascii_case(self.filter_name.trim())
        {
            return Err("filterName and acquisition.filter must name the same filter".into());
        }
        if self.filter_index.is_some_and(|i| i < 0) {
            return Err("filterIndex must be >= 0".into());
        }
        if !self.acquisition.exposure_secs.is_finite() || self.acquisition.exposure_secs <= 0.0 {
            return Err("acquisition.exposureSecs must be positive".into());
        }
        if self.acquisition.bin_x < 1 || self.acquisition.bin_y < 1 {
            return Err("acquisition binning must be at least 1".into());
        }
        if self.acquisition.ccd_temp_c.is_some_and(|t| !t.is_finite())
            || !self.compatibility.temperature_tolerance_c.is_finite()
            || self.compatibility.temperature_tolerance_c < 0.0
        {
            return Err("temperature fields must be finite and the tolerance non-negative".into());
        }
        for (name, value) in [
            ("referencePath", self.reference_path.as_str()),
            ("darkPath", self.dark_path.as_str()),
            ("flatPath", self.flat_path.as_str()),
        ] {
            if !Path::new(value).is_absolute() {
                return Err(format!("{name} must be an absolute path"));
            }
        }
        if self.automatic_completion && !self.enabled {
            return Err("automaticCompletion requires enabled".into());
        }
        Ok(())
    }
}

fn valid_goal_id(id: &str) -> bool {
    (1..=80).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn check_healthy(state: &StoreState) -> Result<(), String> {
    if !state.healthy {
        return Err(POISONED.into());
    }
    Ok(())
}

fn validate_evidence_frame(record: &GoalRecord, frame: &ApertureFrame) -> Result<(), String> {
    if frame.frame_id.trim().is_empty() {
        return Err("frameId must not be empty".into());
    }
    if frame.source_path.trim().is_empty() {
        return Err("sourcePath must not be empty".into());
    }
    if frame.provenance_digest.trim().is_empty() {
        return Err("provenanceDigest must not be empty".into());
    }
    if frame.acquired_at_ms <= record.selected_at_ms {
        return Err("evidence predates the current selection".into());
    }
    let measurement = &record.definition.measurement;
    let region_cells = measurement.region.grid(measurement.scale_arcsec)?.len();
    let background_cells = measurement.background.grid(measurement.scale_arcsec)?.len();
    if frame.signal.len() != region_cells || frame.background.len() != background_cells {
        return Err("evidence samples do not match the measurement grids".into());
    }
    if frame
        .signal
        .iter()
        .chain(frame.background.iter())
        .flatten()
        .any(|v| !v.is_finite())
    {
        return Err("evidence samples must be finite".into());
    }
    Ok(())
}

/// What `add_evidence` did with a frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Admission {
    Added,
    /// Already held under this frame id; the first samples stand.
    Duplicate,
    /// The goal's committed verdict is achieved; intake is closed.
    AlreadyAchieved,
}

struct StoreState {
    records: BTreeMap<String, GoalRecord>,
    healthy: bool,
}

pub struct GoalStore {
    root: PathBuf,
    _lock_file: File,
    state: Mutex<StoreState>,
}

impl GoalStore {
    pub fn open(root: &Path) -> Result<Self, String> {
        fs::create_dir_all(root).map_err(|e| format!("cannot create {}: {e}", root.display()))?;
        let lock_path = root.join(".lock");
        let lock_file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&lock_path)
            .map_err(|e| format!("cannot open {}: {e}", lock_path.display()))?;
        match lock_file.try_lock() {
            Ok(()) => {}
            Err(std::fs::TryLockError::WouldBlock) => {
                return Err(format!(
                    "DepthLock goal store at {} is already open",
                    root.display()
                ));
            }
            Err(e) => {
                return Err(format!("cannot lock {}: {e}", lock_path.display()));
            }
        }
        let mut json_files = Vec::new();
        for entry in
            fs::read_dir(root).map_err(|e| format!("cannot list {}: {e}", root.display()))?
        {
            let entry = entry.map_err(|e| format!("cannot list {}: {e}", root.display()))?;
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) == Some("json") {
                json_files.push(path);
            }
        }
        if json_files.len() > MAX_GOALS {
            return Err(format!(
                "DepthLock store at {} holds more than {MAX_GOALS} goals",
                root.display()
            ));
        }
        let mut records = BTreeMap::new();
        for path in json_files {
            let id = path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or_default() // Why: a non-UTF-8 file stem yields "", which valid_goal_id below rejects
                .to_string();
            if !valid_goal_id(&id) {
                return Err(format!(
                    "DepthLock record file {} is not a valid goal id",
                    path.display()
                ));
            }
            let file =
                File::open(&path).map_err(|e| format!("cannot open {}: {e}", path.display()))?;
            let mut bytes = Vec::new();
            file.take(MAX_RECORD_BYTES + 1)
                .read_to_end(&mut bytes)
                .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
            if bytes.len() as u64 > MAX_RECORD_BYTES {
                return Err(format!(
                    "DepthLock record {} exceeds the 128 MiB limit",
                    path.display()
                ));
            }
            let record: GoalRecord = serde_json::from_slice(&bytes)
                .map_err(|e| format!("corrupt DepthLock record {}: {e}", path.display()))?;
            if record.schema_version != SCHEMA_VERSION {
                return Err(format!(
                    "DepthLock record {} uses unknown schema {}",
                    path.display(),
                    record.schema_version
                ));
            }
            if record.id != id {
                return Err(format!(
                    "DepthLock record {} does not match its file name",
                    path.display()
                ));
            }
            record
                .definition
                .validate()
                .map_err(|e| format!("invalid DepthLock definition in {}: {e}", path.display()))?;
            if record.evidence.len() > MAX_EVIDENCE_PER_GOAL {
                return Err(format!(
                    "DepthLock record {} exceeds {MAX_EVIDENCE_PER_GOAL} evidence rows",
                    path.display()
                ));
            }
            for (key, frame) in &record.evidence {
                if key != &frame.frame_id {
                    return Err(format!(
                        "DepthLock record {} keys evidence under the wrong frame id",
                        path.display()
                    ));
                }
                validate_evidence_frame(&record, frame).map_err(|e| {
                    format!("invalid DepthLock evidence in {}: {e}", path.display())
                })?;
            }
            records.insert(id, record);
        }
        Ok(Self {
            root: root.to_path_buf(),
            _lock_file: lock_file,
            state: Mutex::new(StoreState {
                records,
                healthy: true,
            }),
        })
    }

    pub fn list(&self) -> Result<Vec<GoalRecord>, String> {
        let state = self.state.lock();
        check_healthy(&state)?;
        Ok(state
            .records
            .values()
            .filter(|r| !r.deleted)
            .cloned()
            .collect())
    }

    pub fn get(&self, id: &str) -> Result<GoalRecord, String> {
        let state = self.state.lock();
        check_healthy(&state)?;
        match state.records.get(id) {
            Some(record) if !record.deleted => Ok(record.clone()),
            _ => Err(format!("DepthLock goal {id} does not exist")),
        }
    }

    pub fn create(
        &self,
        id: &str,
        definition: GoalDefinition,
        selected_at_ms: i64,
    ) -> Result<GoalRecord, String> {
        self.create_impl(id, definition, selected_at_ms, 0)
    }

    fn create_impl(
        &self,
        id: &str,
        definition: GoalDefinition,
        selected_at_ms: i64,
        fail_at: u8,
    ) -> Result<GoalRecord, String> {
        if !valid_goal_id(id) {
            return Err(format!("invalid DepthLock goal id {id:?}"));
        }
        definition.validate()?;
        if selected_at_ms <= 0 {
            return Err("selectedAtMs must be positive".into());
        }
        let mut state = self.state.lock();
        check_healthy(&state)?;
        if state.records.contains_key(id) {
            return Err(format!("DepthLock goal {id} already exists"));
        }
        let record = GoalRecord {
            schema_version: SCHEMA_VERSION,
            id: id.to_string(),
            revision: 1,
            definition,
            selected_at_ms,
            evidence_revision: 0,
            evidence: BTreeMap::new(),
            analyzed_evidence_revision: None,
            report: None,
            candidate: None,
            deleted: false,
            last_issue: None,
            history: Vec::new(),
        };
        self.persist(&mut state, id, &record, fail_at)?;
        Ok(record)
    }

    pub fn revise(
        &self,
        id: &str,
        expected_revision: u64,
        definition: GoalDefinition,
        selected_at_ms: i64,
    ) -> Result<GoalRecord, String> {
        self.revise_impl(id, expected_revision, definition, selected_at_ms, 0)
    }

    fn revise_impl(
        &self,
        id: &str,
        expected_revision: u64,
        definition: GoalDefinition,
        selected_at_ms: i64,
        fail_at: u8,
    ) -> Result<GoalRecord, String> {
        definition.validate()?;
        let mut state = self.state.lock();
        check_healthy(&state)?;
        let old = state
            .records
            .get(id)
            .cloned()
            .ok_or_else(|| format!("DepthLock goal {id} does not exist"))?;
        if old.deleted {
            return Err(format!("DepthLock goal {id} was removed"));
        }
        if old.revision != expected_revision {
            return Err(format!("stale revision for DepthLock goal {id}"));
        }
        if selected_at_ms <= old.selected_at_ms {
            return Err("selectedAtMs must move forward on a new selection".into());
        }
        let revision = old
            .revision
            .checked_add(1)
            .ok_or_else(|| "revision overflow".to_string())?;
        let mut history = old.history.clone();
        history.push(ArchivedRevision {
            revision: old.revision,
            definition: old.definition.clone(),
            selected_at_ms: old.selected_at_ms,
            evidence: old
                .evidence
                .values()
                .map(EvidenceReference::from_frame)
                .collect(),
            report: old.report.clone(),
        });
        let record = GoalRecord {
            schema_version: SCHEMA_VERSION,
            id: id.to_string(),
            revision,
            definition,
            selected_at_ms,
            evidence_revision: 0,
            evidence: BTreeMap::new(),
            analyzed_evidence_revision: None,
            report: None,
            candidate: None,
            deleted: false,
            last_issue: None,
            history,
        };
        self.persist(&mut state, id, &record, fail_at)?;
        Ok(record)
    }

    pub fn remove(&self, id: &str, expected_revision: u64) -> Result<(), String> {
        self.remove_impl(id, expected_revision, 0)
    }

    fn remove_impl(&self, id: &str, expected_revision: u64, fail_at: u8) -> Result<(), String> {
        let mut state = self.state.lock();
        check_healthy(&state)?;
        let old = state
            .records
            .get(id)
            .cloned()
            .ok_or_else(|| format!("DepthLock goal {id} does not exist"))?;
        if old.deleted {
            return Err(format!("DepthLock goal {id} was removed"));
        }
        if old.revision != expected_revision {
            return Err(format!("stale revision for DepthLock goal {id}"));
        }
        let mut record = old.clone();
        record.revision = old
            .revision
            .checked_add(1)
            .ok_or_else(|| "revision overflow".to_string())?;
        record.deleted = true;
        record.definition.enabled = false;
        record.definition.automatic_completion = false;
        self.persist(&mut state, id, &record, fail_at)
    }

    /// Change the two preferences that are not part of the measurement.
    /// Evidence, report and revision are untouched: turning automation on
    /// must not throw away a night's frames, and a bound plan's revision
    /// must not go stale because the operator toggled advisory mode.
    pub fn set_preferences(
        &self,
        id: &str,
        expected_revision: u64,
        enabled: bool,
        automatic_completion: bool,
    ) -> Result<GoalRecord, String> {
        if automatic_completion && !enabled {
            return Err("automaticCompletion requires enabled".into());
        }
        let mut state = self.state.lock();
        check_healthy(&state)?;
        let old = state
            .records
            .get(id)
            .cloned()
            .ok_or_else(|| format!("DepthLock goal {id} does not exist"))?;
        if old.deleted {
            return Err(format!("DepthLock goal {id} was removed"));
        }
        if old.revision != expected_revision {
            return Err(format!("stale revision for DepthLock goal {id}"));
        }
        let mut record = old.clone();
        record.definition.enabled = enabled;
        record.definition.automatic_completion = automatic_completion;
        self.persist(&mut state, id, &record, 0)?;
        Ok(record)
    }

    /// Admit one exposure's apertures. An achieved goal stops taking
    /// evidence: its verdict is final for this revision, so later frames can
    /// neither strengthen nor unsettle it (edit the goal to measure again).
    pub fn add_evidence(
        &self,
        id: &str,
        expected_revision: u64,
        frame: ApertureFrame,
    ) -> Result<Admission, String> {
        self.add_evidence_impl(id, expected_revision, frame, 0)
    }

    fn add_evidence_impl(
        &self,
        id: &str,
        expected_revision: u64,
        frame: ApertureFrame,
        fail_at: u8,
    ) -> Result<Admission, String> {
        let mut state = self.state.lock();
        check_healthy(&state)?;
        let old = state
            .records
            .get(id)
            .cloned()
            .ok_or_else(|| format!("DepthLock goal {id} does not exist"))?;
        if old.deleted {
            return Err(format!("DepthLock goal {id} was removed"));
        }
        if !old.definition.enabled {
            return Err("DepthLock goal is disabled; evidence is not accepted".into());
        }
        if old.revision != expected_revision {
            return Err(format!("stale revision for DepthLock goal {id}"));
        }
        if old.analyzed_evidence_revision == Some(old.evidence_revision)
            && old
                .report
                .as_ref()
                .is_some_and(|r| r.state == DepthState::Achieved)
        {
            return Ok(Admission::AlreadyAchieved);
        }
        if old.evidence.contains_key(&frame.frame_id) {
            return Ok(Admission::Duplicate);
        }
        validate_evidence_frame(&old, &frame)?;
        if old.evidence.len() >= MAX_EVIDENCE_PER_GOAL {
            return Err(format!(
                "DepthLock goal {id} already holds {MAX_EVIDENCE_PER_GOAL} evidence rows"
            ));
        }
        let mut record = old.clone();
        record.evidence.insert(frame.frame_id.clone(), frame);
        record.evidence_revision = old
            .evidence_revision
            .checked_add(1)
            .ok_or_else(|| "evidence revision overflow".to_string())?;
        record.analyzed_evidence_revision = None;
        record.report = None;
        record.last_issue = None;
        self.persist(&mut state, id, &record, fail_at)?;
        Ok(Admission::Added)
    }

    pub fn commit_analysis(
        &self,
        id: &str,
        expected_revision: u64,
        expected_evidence_revision: u64,
        report: DepthReport,
        candidate: Option<Candidate>,
    ) -> Result<(), String> {
        self.commit_analysis_impl(
            id,
            expected_revision,
            expected_evidence_revision,
            report,
            candidate,
            0,
        )
    }

    fn commit_analysis_impl(
        &self,
        id: &str,
        expected_revision: u64,
        expected_evidence_revision: u64,
        report: DepthReport,
        candidate: Option<Candidate>,
        fail_at: u8,
    ) -> Result<(), String> {
        let mut state = self.state.lock();
        check_healthy(&state)?;
        let old = state
            .records
            .get(id)
            .cloned()
            .ok_or_else(|| format!("DepthLock goal {id} does not exist"))?;
        if old.deleted {
            return Err(format!("DepthLock goal {id} was removed"));
        }
        if !old.definition.enabled {
            return Err("DepthLock goal is disabled; analysis is not accepted".into());
        }
        if old.revision != expected_revision {
            return Err(format!("stale revision for DepthLock goal {id}"));
        }
        if old.evidence_revision != expected_evidence_revision {
            return Err(format!("stale evidence revision for DepthLock goal {id}"));
        }
        for value in [
            report.score,
            report.conservative_score,
            report.uncertainty_adu,
        ]
        .into_iter()
        .flatten()
        {
            if !value.is_finite() {
                return Err("report contains a non-finite value".into());
            }
        }
        if !report.coverage.is_finite() || !(0.0..=1.0).contains(&report.coverage) {
            return Err("report coverage must be within 0..=1".into());
        }
        if report.evidence_frames > old.evidence.len() {
            return Err("report claims more evidence than the goal holds".into());
        }
        if report.confirmation_frames > report.evidence_frames {
            return Err("report confirmation frames exceed evidence frames".into());
        }
        if let Some(candidate) = &candidate {
            if candidate.measurement != old.definition.measurement
                || candidate.selected_at_ms != old.selected_at_ms
            {
                return Err("candidate does not match the current selection".into());
            }
            if !candidate
                .frame_ids
                .iter()
                .all(|fid| old.evidence.contains_key(fid))
            {
                return Err("candidate references evidence the goal does not hold".into());
            }
        }
        if report.state == DepthState::Achieved {
            let score_met = report
                .conservative_score
                .is_some_and(|s| s >= old.definition.measurement.threshold);
            if candidate.is_none() || !score_met || report.confirmation_frames < CONFIRMATION_FRAMES
            {
                return Err(
                    "an achieved report needs its candidate, threshold and confirmation window"
                        .into(),
                );
            }
        }
        let mut record = old.clone();
        record.report = Some(report);
        record.candidate = candidate;
        record.analyzed_evidence_revision = Some(old.evidence_revision);
        self.persist(&mut state, id, &record, fail_at)
    }

    pub fn record_issue(
        &self,
        id: &str,
        expected_revision: u64,
        reason: String,
    ) -> Result<(), String> {
        self.record_issue_impl(id, expected_revision, reason, 0)
    }

    fn record_issue_impl(
        &self,
        id: &str,
        expected_revision: u64,
        reason: String,
        fail_at: u8,
    ) -> Result<(), String> {
        checked_field("reason", &reason)?;
        let mut state = self.state.lock();
        check_healthy(&state)?;
        let old = state
            .records
            .get(id)
            .cloned()
            .ok_or_else(|| format!("DepthLock goal {id} does not exist"))?;
        if old.deleted {
            return Err(format!("DepthLock goal {id} was removed"));
        }
        if old.revision != expected_revision {
            return Err(format!("stale revision for DepthLock goal {id}"));
        }
        let mut record = old.clone();
        record.last_issue = Some(reason);
        self.persist(&mut state, id, &record, fail_at)
    }

    fn persist(
        &self,
        state: &mut StoreState,
        id: &str,
        record: &GoalRecord,
        fail_at: u8,
    ) -> Result<(), String> {
        let bytes = serde_json::to_vec(record)
            .map_err(|e| format!("cannot serialize DepthLock goal {id}: {e}"))?;
        if let Err(e) = self.write_record_file_at(id, &bytes, fail_at) {
            state.healthy = false;
            return Err(e);
        }
        state.records.insert(id.to_string(), record.clone());
        Ok(())
    }

    fn write_record_file_at(&self, id: &str, bytes: &[u8], fail_at: u8) -> Result<(), String> {
        let pending = self.root.join(format!("{id}.pending"));
        let target = self.root.join(format!("{id}.json"));
        let mut file = File::create(&pending)
            .map_err(|e| format!("cannot write {}: {e}", pending.display()))?;
        file.write_all(bytes)
            .map_err(|e| format!("cannot write {}: {e}", pending.display()))?;
        file.sync_all()
            .map_err(|e| format!("cannot sync {}: {e}", pending.display()))?;
        drop(file);
        if fail_at == 1 {
            return Err("injected persistence failure before rename".into());
        }
        fs::rename(&pending, &target)
            .map_err(|e| format!("cannot commit {}: {e}", target.display()))?;
        if fail_at == 2 {
            return Err("injected persistence failure after rename".into());
        }
        #[cfg(unix)]
        File::open(&self.root)
            .and_then(|dir| dir.sync_all())
            .map_err(|e| format!("cannot sync {}: {e}", self.root.display()))?;
        Ok(())
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use skotiq_imaging::depthlock::{MeasurementSpec, SkyRectangle};
    use std::collections::BTreeSet;

    pub(crate) fn spec() -> MeasurementSpec {
        MeasurementSpec {
            version: 1,
            region: SkyRectangle {
                ra_deg: 90.0,
                dec_deg: 30.0,
                width_arcsec: 40.0,
                height_arcsec: 40.0,
                rotation_deg: 0.0,
            },
            background: SkyRectangle {
                ra_deg: 90.03,
                dec_deg: 30.0,
                width_arcsec: 40.0,
                height_arcsec: 40.0,
                rotation_deg: 0.0,
            },
            scale_arcsec: 10.0,
            threshold: 5.0,
            min_coverage: 0.9,
            systematic_floor_adu: 0.5,
            systematic_floor_source: "Synthetic fixed 0.5 ADU calibration bound".into(),
        }
    }

    fn fixture_path(name: &str) -> String {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("fixture")
            .join(name)
            .to_string_lossy()
            .into_owned()
    }

    pub(crate) fn definition() -> GoalDefinition {
        GoalDefinition {
            label: "IFN wisp".into(),
            project_id: "project-1".into(),
            target_id: "target-1".into(),
            profile_id: "profile-1".into(),
            filter_name: "L".into(),
            filter_index: Some(0),
            reference_path: fixture_path("reference.fits"),
            reference: ReferenceGeometry {
                width: 1024,
                height: 768,
                crval1: 90.0,
                crval2: 30.0,
                crpix1: 512.5,
                crpix2: 384.5,
                cd1_1: -1.0 / 3600.0,
                cd1_2: 0.0,
                cd2_1: 0.0,
                cd2_2: 1.0 / 3600.0,
            },
            acquisition: AcquisitionSettings {
                instrument: "Test Camera".into(),
                filter: "L".into(),
                exposure_secs: 120.0,
                gain: Some(100),
                offset: Some(50),
                bin_x: 1,
                bin_y: 1,
                ccd_temp_c: Some(-10.0),
            },
            compatibility: CompatibilityPolicy::default(),
            dark_path: fixture_path("dark.fits"),
            flat_path: fixture_path("flat.fits"),
            measurement: spec(),
            enabled: true,
            automatic_completion: false,
        }
    }

    #[test]
    fn definitions_are_validated_field_by_field() {
        assert!(definition().validate().is_ok());
        let mut relative = definition();
        relative.dark_path = "dark.fits".into();
        assert!(relative.validate().unwrap_err().contains("darkPath"));
        let mut ungrouped = definition();
        ungrouped.project_id = String::new();
        ungrouped.target_id = String::new();
        ungrouped.profile_id = String::new();
        assert!(ungrouped.validate().is_ok(), "grouping ids are optional");
        let mut unfiltered = definition();
        unfiltered.filter_name = " ".into();
        assert!(unfiltered.validate().is_err());
        let mut mismatched = definition();
        mismatched.acquisition.filter = "Ha".into();
        assert!(mismatched.validate().unwrap_err().contains("same filter"));
        let mut negative = definition();
        negative.filter_index = Some(-1);
        assert!(negative.validate().is_err());
        let mut automatic_but_disabled = definition();
        automatic_but_disabled.enabled = false;
        automatic_but_disabled.automatic_completion = true;
        assert!(automatic_but_disabled.validate().is_err());
    }

    #[test]
    fn preferences_change_without_touching_evidence_or_revision() {
        let dir = tempfile::tempdir().unwrap();
        let store = GoalStore::open(dir.path()).unwrap();
        store.create("goal-1", definition(), 100).unwrap();
        store
            .add_evidence("goal-1", 1, evidence("frame1", 101))
            .unwrap();
        store
            .commit_analysis("goal-1", 1, 1, collecting_report(), None)
            .unwrap();

        let record = store.set_preferences("goal-1", 1, true, true).unwrap();
        assert_eq!(record.revision, 1);
        assert!(record.definition.automatic_completion);
        assert_eq!(record.evidence.len(), 1);
        assert!(record.report.is_some());

        assert!(store.set_preferences("goal-1", 2, true, false).is_err());
        assert!(store.set_preferences("goal-1", 1, false, true).is_err());
        let disabled = store.set_preferences("goal-1", 1, false, false).unwrap();
        assert!(!disabled.definition.enabled);
        drop(store);

        let reopened = GoalStore::open(dir.path()).unwrap();
        let record = reopened.get("goal-1").unwrap();
        assert!(!record.definition.enabled);
        assert_eq!(record.evidence.len(), 1);
    }

    fn evidence(id: &str, acquired_at_ms: i64) -> ApertureFrame {
        ApertureFrame {
            frame_id: id.to_string(),
            acquired_at_ms,
            source_path: fixture_path(&format!("{id}.fits")),
            provenance_digest: "context1".into(),
            signal: vec![Some(1.0); 16],
            background: vec![Some(0.0); 16],
        }
    }

    fn collecting_report() -> DepthReport {
        DepthReport {
            state: DepthState::Collecting,
            score: Some(1.0),
            conservative_score: Some(1.5),
            uncertainty_adu: Some(0.2),
            coverage: 0.5,
            evidence_frames: 1,
            excluded_frames: 0,
            confirmation_frames: 0,
            reason: "collecting".into(),
            forecast: None,
        }
    }

    fn candidate() -> Candidate {
        Candidate {
            frame_ids: BTreeSet::from(["frame1".to_string()]),
            latest_acquired_at_ms: 101,
            measurement: spec(),
            selected_at_ms: 100,
            provenance_digest: "context1".into(),
        }
    }

    #[test]
    fn an_empty_root_opens_an_empty_store() {
        let dir = tempfile::tempdir().unwrap();
        let store = GoalStore::open(dir.path()).unwrap();
        assert!(store.list().unwrap().is_empty());
        assert!(store.get("goal-1").is_err());
    }

    #[test]
    fn a_second_open_on_the_same_root_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let store = GoalStore::open(dir.path()).unwrap();
        let second = GoalStore::open(dir.path());
        assert!(second.is_err());
        assert!(store.list().unwrap().is_empty());
    }

    #[test]
    fn create_evidence_and_analysis_survive_a_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let store = GoalStore::open(dir.path()).unwrap();
        store.create("goal-1", definition(), 100).unwrap();
        assert_eq!(
            store
                .add_evidence("goal-1", 1, evidence("frame1", 101))
                .unwrap(),
            Admission::Added
        );
        store
            .commit_analysis("goal-1", 1, 1, collecting_report(), Some(candidate()))
            .unwrap();
        store
            .record_issue("goal-1", 1, "operator note".into())
            .unwrap();
        drop(store);

        let reopened = GoalStore::open(dir.path()).unwrap();
        let record = reopened.get("goal-1").unwrap();
        assert_eq!(record.schema_version, 1);
        assert_eq!(record.revision, 1);
        assert_eq!(record.selected_at_ms, 100);
        assert_eq!(record.evidence_revision, 1);
        assert_eq!(record.evidence.len(), 1);
        assert_eq!(
            record.evidence["frame1"].source_path,
            fixture_path("frame1.fits")
        );
        assert_eq!(record.analyzed_evidence_revision, Some(1));
        assert_eq!(
            record.report.as_ref().unwrap().state,
            DepthState::Collecting
        );
        assert_eq!(
            record.candidate.as_ref().unwrap().frame_ids,
            BTreeSet::from(["frame1".to_string()])
        );
        assert_eq!(record.last_issue.as_deref(), Some("operator note"));
        assert!(!record.deleted);
        assert!(record.history.is_empty());
    }

    #[test]
    fn a_reprocessed_frame_id_keeps_the_first_samples() {
        let dir = tempfile::tempdir().unwrap();
        let store = GoalStore::open(dir.path()).unwrap();
        store.create("goal-1", definition(), 100).unwrap();
        assert_eq!(
            store
                .add_evidence("goal-1", 1, evidence("frame1", 101))
                .unwrap(),
            Admission::Added
        );
        let mut replacement = evidence("frame1", 102);
        replacement.signal = vec![Some(99.0); 16];
        assert_eq!(
            store.add_evidence("goal-1", 1, replacement).unwrap(),
            Admission::Duplicate
        );
        let record = store.get("goal-1").unwrap();
        assert_eq!(record.evidence_revision, 1);
        assert_eq!(record.evidence["frame1"].signal, vec![Some(1.0); 16]);
        assert_eq!(record.evidence["frame1"].acquired_at_ms, 101);
    }

    #[test]
    fn a_disabled_goal_rejects_ingestion() {
        let dir = tempfile::tempdir().unwrap();
        let store = GoalStore::open(dir.path()).unwrap();
        let mut disabled = definition();
        disabled.enabled = false;
        store.create("goal-1", disabled, 100).unwrap();
        assert!(store
            .add_evidence("goal-1", 1, evidence("frame1", 101))
            .is_err());
        assert!(store
            .commit_analysis("goal-1", 1, 0, collecting_report(), None)
            .is_err());
    }

    #[test]
    fn stale_revisions_are_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let store = GoalStore::open(dir.path()).unwrap();
        store.create("goal-1", definition(), 100).unwrap();
        store
            .add_evidence("goal-1", 1, evidence("frame1", 101))
            .unwrap();
        assert!(store
            .add_evidence("goal-1", 2, evidence("frame2", 102))
            .is_err());
        assert!(store
            .commit_analysis("goal-1", 2, 1, collecting_report(), None)
            .is_err());
        assert!(store
            .commit_analysis("goal-1", 1, 0, collecting_report(), None)
            .is_err());
        assert!(store
            .commit_analysis("goal-1", 1, 1, collecting_report(), None)
            .is_ok());
    }

    #[test]
    fn revise_archives_the_old_selection_and_rejects_late_jobs() {
        let dir = tempfile::tempdir().unwrap();
        let store = GoalStore::open(dir.path()).unwrap();
        store.create("goal-1", definition(), 100).unwrap();
        store
            .add_evidence("goal-1", 1, evidence("frame1", 101))
            .unwrap();
        store
            .commit_analysis("goal-1", 1, 1, collecting_report(), Some(candidate()))
            .unwrap();

        let mut next = definition();
        next.filter_name = "Ha".into();
        next.acquisition.filter = "Ha".into();
        let revised = store.revise("goal-1", 1, next, 200).unwrap();
        assert_eq!(revised.revision, 2);
        assert_eq!(revised.selected_at_ms, 200);
        assert_eq!(revised.evidence_revision, 0);
        assert!(revised.evidence.is_empty());
        assert!(revised.report.is_none());
        assert!(revised.candidate.is_none());
        assert_eq!(revised.history.len(), 1);
        let archived = &revised.history[0];
        assert_eq!(archived.revision, 1);
        assert_eq!(archived.selected_at_ms, 100);
        assert_eq!(archived.definition.filter_name, "L");
        assert_eq!(archived.evidence.len(), 1);
        assert_eq!(archived.evidence[0].frame_id, "frame1");
        assert_eq!(
            archived.evidence[0].source_path,
            fixture_path("frame1.fits")
        );
        assert_eq!(archived.evidence[0].provenance_digest, "context1");
        assert!(archived.report.is_some());

        assert!(store
            .add_evidence("goal-1", 1, evidence("frame2", 201))
            .is_err());
        assert!(store
            .commit_analysis("goal-1", 1, 1, collecting_report(), None)
            .is_err());
        assert!(store.revise("goal-1", 2, definition(), 150).is_err());
    }

    #[test]
    fn a_removed_goal_is_a_tombstone_across_restarts() {
        let dir = tempfile::tempdir().unwrap();
        let store = GoalStore::open(dir.path()).unwrap();
        store.create("goal-1", definition(), 100).unwrap();
        assert!(store.create("goal-1", definition(), 200).is_err());
        store.remove("goal-1", 1).unwrap();
        drop(store);

        let reopened = GoalStore::open(dir.path()).unwrap();
        assert!(reopened.list().unwrap().is_empty());
        assert!(reopened.get("goal-1").is_err());
        assert!(reopened.create("goal-1", definition(), 300).is_err());
        assert!(reopened.remove("goal-1", 2).is_err());
    }

    #[test]
    fn corrupt_or_unknown_schema_records_fail_open() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("goal-1.json"), b"not json").unwrap();
        assert!(GoalStore::open(dir.path()).is_err());

        fs::remove_file(dir.path().join("goal-1.json")).unwrap();
        let mut record = GoalRecord {
            schema_version: 99,
            id: "goal-1".into(),
            revision: 1,
            definition: definition(),
            selected_at_ms: 100,
            evidence_revision: 0,
            evidence: BTreeMap::new(),
            analyzed_evidence_revision: None,
            report: None,
            candidate: None,
            deleted: false,
            last_issue: None,
            history: Vec::new(),
        };
        fs::write(
            dir.path().join("goal-1.json"),
            serde_json::to_vec(&record).unwrap(),
        )
        .unwrap();
        assert!(GoalStore::open(dir.path()).is_err());

        record.schema_version = 1;
        fs::write(
            dir.path().join("goal-1.json"),
            serde_json::to_vec(&record).unwrap(),
        )
        .unwrap();
        assert!(GoalStore::open(dir.path()).is_ok());
    }

    #[test]
    fn pending_files_are_ignored_and_committed_records_survive() {
        let dir = tempfile::tempdir().unwrap();
        let store = GoalStore::open(dir.path()).unwrap();
        store.create("goal-1", definition(), 100).unwrap();
        fs::write(dir.path().join("goal-2.pending"), b"partial write").unwrap();
        drop(store);

        let reopened = GoalStore::open(dir.path()).unwrap();
        let goals = reopened.list().unwrap();
        assert_eq!(goals.len(), 1);
        assert_eq!(goals[0].id, "goal-1");
    }

    #[test]
    fn a_fault_before_rename_keeps_the_old_record_and_poisons_the_store() {
        let dir = tempfile::tempdir().unwrap();
        let store = GoalStore::open(dir.path()).unwrap();
        store.create("goal-1", definition(), 100).unwrap();
        assert!(store.create_impl("goal-2", definition(), 100, 1).is_err());
        let err = store.create("goal-3", definition(), 100).unwrap_err();
        assert_eq!(err, POISONED);
        assert!(store.list().is_err());
        drop(store);

        let reopened = GoalStore::open(dir.path()).unwrap();
        let goals = reopened.list().unwrap();
        assert_eq!(goals.len(), 1);
        assert_eq!(goals[0].id, "goal-1");
    }

    #[test]
    fn a_fault_after_rename_never_splits_report_from_evidence() {
        let dir = tempfile::tempdir().unwrap();
        let store = GoalStore::open(dir.path()).unwrap();
        store.create("goal-1", definition(), 100).unwrap();
        store
            .add_evidence("goal-1", 1, evidence("frame1", 101))
            .unwrap();
        assert!(store
            .commit_analysis_impl("goal-1", 1, 1, collecting_report(), Some(candidate()), 2)
            .is_err());
        assert_eq!(store.list().unwrap_err(), POISONED);
        drop(store);

        let reopened = GoalStore::open(dir.path()).unwrap();
        let record = reopened.get("goal-1").unwrap();
        assert_eq!(record.evidence.len(), 1);
        assert!(record.report.is_some());
        assert_eq!(record.analyzed_evidence_revision, Some(1));
    }
}
