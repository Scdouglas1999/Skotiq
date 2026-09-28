//! Which of a failed run's many complaints is the REASON it failed.
//!
//! A run that dies does not report one problem, it reports a cascade. The
//! executor cancels the node tree, every device operation still in flight
//! returns "cancelled", and each of those cancellations arrives as a failure
//! of its own — after the fault that started it. Picking the most recent one
//! therefore picks the cleanup, never the cause.
//!
//! That is not hypothetical. On 2026-09-15 a run on the owner's rig lost
//! guiding after an autofocus interlude, trailed three frames, tripped the
//! consecutive-reject limit and was abandoned by recovery. The only thing he
//! was shown was:
//!
//! ```text
//! Change Filter failed: Operation cancelled
//! ```
//!
//! — the filter wheel's wait loop noticing, one second later, that the
//! cancellation token had been set. Everything that mattered was in the log
//! and none of it reached him.
//!
//! The rule, then: **an operation cancelled because the run is already failing
//! is never the failure reason.** See [`FailureChain::report`].

use crate::executor::types::ExecutorEvent;
use crate::NodeStatus;
use tokio::sync::broadcast;

/// How much authority one of a failed run's complaints has over the others.
///
/// Ordered by authority, weakest first, so `Ord` is the ranking.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
enum Authority {
    /// The run was already ending and this operation was cancelled by the
    /// teardown. Never a cause — an effect of one.
    CancellationArtefact,
    /// A subsystem reported a real fault of its own: an instruction that failed
    /// for its own reasons, a grader that stopped the run, a flip that did not
    /// complete.
    Fault,
}

/// One link in a failed run's chain, as it arrived.
#[derive(Debug, Clone)]
struct FailureLink {
    message: String,
    authority: Authority,
}

/// Is this message a run that was cancelled, rather than a run that broke?
///
/// Matched on the message because that is the only thing every producer of a
/// cancelled operation has in common: the token is checked in a dozen wait
/// loops (`InstructionContext::check_cancelled`, the filter-wheel and
/// cover-calibrator settle loops, the wait instructions) and each formats its
/// own sentence around the same vocabulary. A `NodeStatus::Cancelled` would be
/// a cleaner signal, but the cancellations that matter here do not use it:
/// they surface as a `Failure` whose message says the operation was cancelled,
/// which is exactly how "Change Filter failed: Operation cancelled" became a
/// run's official reason.
///
/// Deliberately narrow. It matches the cancellation vocabulary and the
/// executor's own abort notices, and nothing else — a message that merely
/// mentions an abort ("Dither failed after frame 3/8: ...") stays a fault.
fn is_cancellation_artefact(message: &str) -> bool {
    const ARTEFACT_PHRASES: [&str; 4] = [
        "operation cancelled",
        "operation canceled",
        "sequence cancelled",
        "sequence canceled",
    ];
    let lowered = message.to_ascii_lowercase();
    ARTEFACT_PHRASES
        .iter()
        .any(|phrase| lowered.contains(phrase))
}

/// The reason a failed run should report, and the cascade behind it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct RunFailureReport {
    /// The chosen cause, or `None` when the run reported nothing but
    /// cancellations (or nothing at all).
    pub(crate) cause: Option<String>,
    /// Everything the run reported, in the order it happened, cause included.
    /// Kept so the cause is an answer the operator can check rather than one he
    /// has to trust.
    pub(crate) cascade: Vec<String>,
}

/// A failed run's complaints, folded in as they arrive, and the point after
/// which the run was last seen carrying on.
#[derive(Debug, Default)]
struct FailureChain {
    links: Vec<FailureLink>,
    /// Index into `links` of the first complaint after the run last carried
    /// on past a fault. Everything before it was survived.
    since_carried_on: usize,
}

impl FailureChain {
    fn absorb(&mut self, event: &ExecutorEvent) {
        match event {
            ExecutorEvent::InstructionFailed { node_name, message } => {
                self.links
                    .push(classify(format!("{}: {}", node_name, message), message));
            }
            ExecutorEvent::Error { message } => {
                self.links.push(classify(message.clone(), message));
            }
            // A node of the sequence finishing successfully means the run
            // carried on: whatever failed before it was retried, recovered or
            // absorbed by a Recovery node, and is not why a later failure
            // ended the run. A trigger's interlude (`trigger:<id>:<action>`)
            // runs beside the tree rather than in it, so its success says
            // nothing about the tree.
            ExecutorEvent::NodeCompleted {
                id,
                status: NodeStatus::Success,
            } if !id.starts_with("trigger:") => {
                self.since_carried_on = self.links.len();
            }
            _ => {}
        }
    }

    /// Choose the reason this run failed.
    ///
    /// The rule, in order:
    ///
    ///  1. A `structural` reason — a refusal decided before or independently
    ///     of execution, like a preflight check or an unreachable instruction —
    ///     wins outright. The run could not have worked; nothing that happened
    ///     afterwards explains more.
    ///  2. Otherwise the FIRST fault reported since the run last carried on.
    ///     It is the one that had no earlier failure to blame, so it is the one
    ///     the operator has to fix. A fault the run survived is not a
    ///     candidate: on a rig whose USB drops reconnect routinely, the first
    ///     fault of the whole night would blame a 21:00 reconnect for a 03:00
    ///     guider death.
    ///  3. Otherwise nothing: a run whose only complaints were cancellations
    ///     was stopped, not broken, and the caller keeps its own verdict rather
    ///     than quoting a teardown step back at the operator.
    ///
    /// `Error` events count as faults alongside `InstructionFailed` because
    /// that is where the most useful causes actually live. The grader's
    /// reject-storm escalation is an `Error`, and it carries the HFR that
    /// failed, the threshold it failed against and the path of the reject —
    /// the whole answer, in the one sentence the operator needed.
    fn report(self, structural: Option<String>) -> RunFailureReport {
        let cascade: Vec<String> = self.links.iter().map(|link| link.message.clone()).collect();
        let cause = structural.or_else(|| {
            self.links[self.since_carried_on..]
                .iter()
                .find(|link| link.authority == Authority::Fault)
                .map(|link| link.message.clone())
        });
        RunFailureReport { cause, cascade }
    }
}

/// Follows a run's events from its start and hands back its failure report
/// at the end.
///
/// It reads the executor's event channel as the run goes rather than draining
/// it at the end. The channel holds 256 events and every frame and autofocus
/// step sends several, so a receiver left unread until the terminal handler
/// kept only the last 256: a fault further back than that was gone, and the
/// run reported no cause, or a later one. `Lagged` is still skipped rather
/// than treated as end-of-stream, for a collector starved of the scheduler.
pub(crate) struct FailureCollector {
    stop: tokio::sync::oneshot::Sender<()>,
    task: tokio::task::JoinHandle<FailureChain>,
}

impl FailureCollector {
    /// Start following `rx`. Subscribe it BEFORE the node tree runs so every
    /// complaint the run makes is seen.
    pub(crate) fn spawn(mut rx: broadcast::Receiver<ExecutorEvent>) -> Self {
        let (stop, mut stop_rx) = tokio::sync::oneshot::channel::<()>();
        let task = tokio::spawn(async move {
            let mut chain = FailureChain::default();
            loop {
                tokio::select! {
                    biased;
                    event = rx.recv() => match event {
                        Ok(event) => chain.absorb(&event),
                        Err(broadcast::error::RecvError::Lagged(_)) => {}
                        Err(broadcast::error::RecvError::Closed) => break,
                    },
                    // Asked to finish, or dropped with the run: take what is
                    // already buffered and stop.
                    _ = &mut stop_rx => {
                        loop {
                            match rx.try_recv() {
                                Ok(event) => chain.absorb(&event),
                                Err(broadcast::error::TryRecvError::Lagged(_)) => {}
                                Err(_) => break,
                            }
                        }
                        break;
                    }
                }
            }
            chain
        });
        FailureCollector { stop, task }
    }

    /// Stop following and choose the reason the run failed (see
    /// [`FailureChain::report`]). Every event the tree sent was sent before
    /// this is called, so it is either folded in already or still buffered.
    pub(crate) async fn finish(self, structural: Option<String>) -> RunFailureReport {
        let FailureCollector { stop, task } = self;
        let _ = stop.send(());
        match task.await {
            Ok(chain) => chain.report(structural),
            Err(error) => {
                tracing::warn!(
                    "The run's failure collector ended abnormally ({}); reporting without \
                     its cascade",
                    error
                );
                RunFailureReport {
                    cause: structural,
                    cascade: Vec::new(),
                }
            }
        }
    }
}

/// Build a link, ranking it on the message the producer actually wrote.
///
/// `message` is the producer's own text and `rendered` is how the operator will
/// read it; for an `InstructionFailed` those differ by the `"<node>: "` prefix,
/// which must not be what a match hinges on.
fn classify(rendered: String, message: &str) -> FailureLink {
    FailureLink {
        message: rendered,
        authority: if is_cancellation_artefact(message) {
            Authority::CancellationArtefact
        } else {
            Authority::Fault
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Verbatim from `nightshade.log.2026-09-15`, the run the owner lost.
    const REJECT_STORM: &str = "Image grading: 3 consecutive rejects (limit 3). Sequence paused \
         for inspection. Frame 1/1, last reason: HFR 15.61 px exceeds absolute threshold 3.50 px. \
         Most recent reject: C:\\Images\\NGC7380\\Reject\\NGC7380_OIII_0001.fits. Accepted so \
         far: 0, rejected: 3.";

    fn drain(events: Vec<ExecutorEvent>, structural: Option<String>) -> RunFailureReport {
        let mut chain = FailureChain::default();
        for event in &events {
            chain.absorb(event);
        }
        chain.report(structural)
    }

    #[test]
    fn the_cancelled_teardown_step_is_not_the_reason() {
        let report = drain(
            vec![
                ExecutorEvent::Error {
                    message: REJECT_STORM.to_string(),
                },
                ExecutorEvent::InstructionFailed {
                    node_name: "Change Filter".to_string(),
                    message: "Operation cancelled".to_string(),
                },
            ],
            None,
        );

        assert_eq!(
            report.cause.as_deref(),
            Some(REJECT_STORM),
            "the reject storm is what ended the run; the filter change was cancelled BY the \
             teardown and reported one second later"
        );
        assert_eq!(
            report.cascade.len(),
            2,
            "the cancelled step stays available underneath the cause"
        );
        assert!(report.cascade[1].starts_with("Change Filter: "));
    }

    #[test]
    fn the_first_fault_wins_over_later_ones() {
        let report = drain(
            vec![
                ExecutorEvent::InstructionFailed {
                    node_name: "Slew".to_string(),
                    message: "mount reported a limit".to_string(),
                },
                ExecutorEvent::InstructionFailed {
                    node_name: "Center".to_string(),
                    message: "no solve".to_string(),
                },
            ],
            None,
        );

        assert_eq!(
            report.cause.as_deref(),
            Some("Slew: mount reported a limit"),
            "the later failure had an earlier one to blame; the first did not"
        );
    }

    #[test]
    fn a_structural_refusal_outranks_every_fault() {
        let report = drain(
            vec![ExecutorEvent::Error {
                message: REJECT_STORM.to_string(),
            }],
            Some(
                "2 instructions in this sequence are attached to an instruction that cannot \
                  hold children"
                    .to_string(),
            ),
        );

        assert!(
            report
                .cause
                .as_deref()
                .is_some_and(|cause| cause.starts_with("2 instructions")),
            "a run that could never have worked is explained by that, not by what it managed \
             to do first"
        );
    }

    #[test]
    fn a_run_that_only_reported_cancellations_names_no_cause() {
        let report = drain(
            vec![
                ExecutorEvent::Error {
                    message: "Sequence cancelled".to_string(),
                },
                ExecutorEvent::InstructionFailed {
                    node_name: "Change Filter".to_string(),
                    message: "Operation cancelled".to_string(),
                },
            ],
            None,
        );

        assert_eq!(
            report.cause, None,
            "a stopped run must keep its own verdict rather than quote a teardown step"
        );
        assert_eq!(report.cascade.len(), 2);
    }

    #[test]
    fn an_abort_a_node_reported_itself_is_still_a_fault() {
        let report = drain(
            vec![ExecutorEvent::Error {
                message: "Dither failed after frame 3/8: No active guider configured".to_string(),
            }],
            None,
        );

        assert!(
            report.cause.is_some(),
            "the classifier matches the cancellation vocabulary, not any mention of a run \
             ending"
        );
    }

    /// The executor's event channel holds 256 events, and every frame and
    /// autofocus step sends several progress events. A fault followed by more
    /// than a channel's worth of them before the run ends must still be the
    /// cause.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_fault_further_back_than_the_channel_holds_is_still_the_cause() {
        let (tx, rx) = broadcast::channel(256);
        let collector = FailureCollector::spawn(rx);
        tx.send(ExecutorEvent::Error {
            message: REJECT_STORM.to_string(),
        })
        .expect("receiver is alive");
        // Progress arrives from other tasks over a run, not in one burst.
        for sent in 0..300 {
            tx.send(ExecutorEvent::ProgressUpdated(Box::default()))
                .expect("receiver is alive");
            if sent % 32 == 0 {
                tokio::time::sleep(std::time::Duration::from_millis(1)).await;
            }
        }
        tx.send(ExecutorEvent::InstructionFailed {
            node_name: "Change Filter".to_string(),
            message: "Operation cancelled".to_string(),
        })
        .expect("receiver is alive");

        let report = collector.finish(None).await;
        assert_eq!(report.cause.as_deref(), Some(REJECT_STORM));
        assert_eq!(report.cascade.len(), 2);
    }

    #[test]
    fn a_fault_the_run_carried_on_past_is_not_the_cause() {
        let report = drain(
            vec![
                ExecutorEvent::InstructionFailed {
                    node_name: "Take Exposure".to_string(),
                    message: "camera disconnected".to_string(),
                },
                ExecutorEvent::NodeCompleted {
                    id: "expose".to_string(),
                    status: NodeStatus::Success,
                },
                ExecutorEvent::Error {
                    message: REJECT_STORM.to_string(),
                },
            ],
            None,
        );
        assert_eq!(report.cause.as_deref(), Some(REJECT_STORM));
        assert_eq!(
            report.cascade.len(),
            2,
            "the survived fault stays on record"
        );
    }

    #[test]
    fn a_trigger_interlude_succeeding_does_not_clear_the_fault() {
        let report = drain(
            vec![
                ExecutorEvent::Error {
                    message: REJECT_STORM.to_string(),
                },
                ExecutorEvent::NodeCompleted {
                    id: "trigger:hfr_degraded:autofocus".to_string(),
                    status: NodeStatus::Success,
                },
            ],
            None,
        );
        assert_eq!(report.cause.as_deref(), Some(REJECT_STORM));
    }

    #[test]
    fn a_run_that_reported_nothing_names_no_cause() {
        let report = drain(vec![], None);
        assert_eq!(report, RunFailureReport::default());
    }
}
