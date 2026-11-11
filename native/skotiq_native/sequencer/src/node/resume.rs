//! Where a run stands inside its loops and exposure bursts.
//!
//! The node tree keeps this current as it runs, so a checkpoint saved at any
//! moment can say how far each loop and burst got, and a resumed run picks up
//! from there instead of running the plan again.

use crate::node::Node;
use crate::{NodeId, NodeType};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

#[derive(Default)]
struct Record {
    /// Passes each Loop node has finished in its current run.
    loop_passes_finished: HashMap<NodeId, u32>,
    /// The plan's Take Exposures nodes. Smart Exposure and photometry nodes
    /// run their bursts under their own id and resume them from their own
    /// state, so only these are counted here.
    bursts: HashSet<NodeId>,
    /// Frames each Take Exposures burst has taken so far, kept while the burst
    /// runs and after a stop cuts it short.
    frames_taken: HashMap<NodeId, u32>,
    /// Nodes inside a loop whose recorded status is from an earlier pass: a
    /// loop starting a new pass runs them again, so that status is not
    /// progress.
    from_earlier_pass: HashSet<NodeId>,
}

/// Shared handle; cloning shares the record.
#[derive(Clone, Default)]
pub struct ResumeRecord(Arc<parking_lot::RwLock<Record>>);

/// What a checkpoint stores from the record.
pub struct ResumeSnapshot {
    pub loop_passes_finished: HashMap<NodeId, u32>,
    pub frames_taken: HashMap<NodeId, u32>,
    pub from_earlier_pass: HashSet<NodeId>,
}

impl ResumeRecord {
    /// The record a run of `root` starts with: the loop passes and burst
    /// frames its checkpoint recorded, or nothing for a fresh start.
    pub fn new(
        root: &dyn Node,
        loop_passes_finished: HashMap<NodeId, u32>,
        frames_taken: HashMap<NodeId, u32>,
    ) -> Self {
        let mut bursts = HashSet::new();
        collect_bursts(root, &mut bursts);
        Self(Arc::new(parking_lot::RwLock::new(Record {
            loop_passes_finished,
            bursts,
            frames_taken,
            from_earlier_pass: HashSet::new(),
        })))
    }

    /// A loop starts a pass after `passes_finished` finished ones: what its
    /// body recorded belongs to the pass before, so inner loops start over,
    /// bursts start from their first frame and the body's statuses stop
    /// counting as progress until each node runs again.
    pub fn begin_pass(
        &self,
        loop_id: &NodeId,
        passes_finished: u32,
        body: impl IntoIterator<Item = NodeId>,
    ) {
        let mut record = self.0.write();
        for id in body {
            record.loop_passes_finished.remove(&id);
            record.frames_taken.remove(&id);
            record.from_earlier_pass.insert(id);
        }
        if passes_finished > 0 {
            record
                .loop_passes_finished
                .insert(loop_id.clone(), passes_finished);
        }
    }

    pub fn finish_pass(&self, loop_id: &NodeId, passes_finished: u32) {
        self.0
            .write()
            .loop_passes_finished
            .insert(loop_id.clone(), passes_finished);
    }

    /// A node starts running in the current pass.
    pub fn node_started(&self, id: &NodeId) {
        let mut record = self.0.write();
        if !record.from_earlier_pass.is_empty() {
            record.from_earlier_pass.remove(id);
        }
    }

    /// Frames the burst of `id` has already taken in this pass.
    pub fn frames_taken(&self, id: &str) -> u32 {
        self.0.read().frames_taken.get(id).copied().unwrap_or(0)
    }

    pub fn set_frames_taken(&self, id: &str, frames: u32) {
        let mut record = self.0.write();
        if record.bursts.contains(id) {
            record.frames_taken.insert(id.to_string(), frames);
        }
    }

    /// The burst of `id` ended other than by a stop; nothing of it is left
    /// to resume.
    pub fn burst_ended(&self, id: &str) {
        self.0.write().frames_taken.remove(id);
    }

    pub fn snapshot(&self) -> ResumeSnapshot {
        let record = self.0.read();
        ResumeSnapshot {
            loop_passes_finished: record.loop_passes_finished.clone(),
            frames_taken: record.frames_taken.clone(),
            from_earlier_pass: record.from_earlier_pass.clone(),
        }
    }
}

fn collect_bursts(node: &dyn Node, out: &mut HashSet<NodeId>) {
    if matches!(node.node_type(), NodeType::TakeExposure(_)) {
        out.insert(node.id().clone());
    }
    for child in node.children() {
        collect_bursts(child.as_ref(), out);
    }
}

/// The steps whose progress a resume keeps: those that take frames (a burst,
/// or a container whose subtree holds one). A resume skips them when they
/// finished and continues their loops from the passes they finished. Every
/// other step runs again from its start, because what it did may not hold
/// after the stop: the stop can park the mount and stop guiding, so
/// unparking, slewing, centering and starting the guider are repeated before
/// imaging continues.
pub fn imaging_steps(root: &dyn Node) -> HashSet<NodeId> {
    let mut out = HashSet::new();
    collect_imaging_steps(root, &mut out);
    out
}

/// Whether `node` takes frames; collects it and every descendant that does.
fn collect_imaging_steps(node: &dyn Node, out: &mut HashSet<NodeId>) -> bool {
    let mut takes_frames = matches!(
        node.node_type(),
        NodeType::TakeExposure(_)
            | NodeType::SmartExposure(_)
            | NodeType::SciencePhotometry(_)
            | NodeType::FlatWizard(_)
    );
    for child in node.children() {
        takes_frames |= collect_imaging_steps(child.as_ref(), out);
    }
    if takes_frames {
        out.insert(node.id().clone());
    }
    takes_frames
}
