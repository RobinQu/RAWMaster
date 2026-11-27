//! Durable-job state machine for the 040/041 backbone PoC.
//!
//! The production design uses PostgreSQL and leases. This module keeps the same
//! externally observable semantics in memory so the team can test idempotency,
//! lane priority, cancellation, retry and single publication before adding the
//! database and worker processes.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, Eq, PartialEq, Ord, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Lane {
    Library,
    SceneFinal,
    LegacyFinal,
    ModelPrefix,
    Generative,
    Background,
}

impl Lane {
    fn order(self) -> u8 {
        match self {
            Self::Library => 0,
            Self::SceneFinal => 1,
            Self::LegacyFinal => 2,
            Self::ModelPrefix => 3,
            Self::Generative => 4,
            Self::Background => 5,
        }
    }
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum JobState {
    Submitted,
    Queued,
    Admitted,
    Running,
    Staged,
    Published,
    Failed,
    Cancelled,
    Reconcile,
    Expired,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum JobKind {
    SceneRenderFinal,
    SceneRenderBatch,
    LegacyRenderFinal,
    ModelPrefix,
    Generative,
    ProxyGenerate,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobRequest {
    pub library_id: String,
    pub job_id: String,
    pub kind: JobKind,
    pub lane: Lane,
    pub priority: i32,
    pub request_hash: String,
    pub input_content_ids: Vec<String>,
    pub scene_graph_hash: Option<String>,
    pub output_state_hash: Option<String>,
    pub model_program_hash: Option<String>,
    pub compatibility_route: Option<String>,
    pub delivery_target: Option<String>,
    pub format: Option<String>,
    pub template_id: Option<String>,
    pub batch_id: Option<String>,
    pub target_head: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub request: JobRequest,
    pub state: JobState,
    pub attempts: u32,
    pub token: Option<String>,
    pub result: Option<String>,
    pub receipt: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SubmitOutcome {
    Created,
    Existing,
    Conflict,
    Invalid,
}

#[derive(Debug, Clone, PartialEq)]
pub enum QueueError {
    Missing,
    WrongState,
    StaleToken,
    AlreadyPublished,
    Invalid,
}

pub struct JobQueue {
    jobs: HashMap<String, Job>,
    sequence: u64,
}

pub struct Lease {
    pub key: String,
    pub token: String,
    pub job: Job,
}

fn key(library_id: &str, job_id: &str) -> String {
    format!("{library_id}\u{1f}{job_id}")
}

impl Default for JobQueue {
    fn default() -> Self {
        Self::new()
    }
}

impl JobQueue {
    pub fn new() -> Self {
        Self {
            jobs: HashMap::new(),
            sequence: 0,
        }
    }

    pub fn submit(&mut self, request: JobRequest) -> (SubmitOutcome, Option<Job>) {
        if request.library_id.is_empty()
            || request.job_id.is_empty()
            || request.request_hash.is_empty()
            || request.input_content_ids.is_empty()
        {
            return (SubmitOutcome::Invalid, None);
        }
        let key = key(&request.library_id, &request.job_id);
        if let Some(existing) = self.jobs.get(&key) {
            let outcome = if existing.request.request_hash == request.request_hash {
                SubmitOutcome::Existing
            } else {
                SubmitOutcome::Conflict
            };
            return (outcome, Some(existing.clone()));
        }
        self.sequence += 1;
        let job = Job {
            request,
            state: JobState::Queued,
            attempts: 0,
            token: None,
            result: None,
            receipt: None,
            error: None,
        };
        self.jobs.insert(key, job.clone());
        (SubmitOutcome::Created, Some(job))
    }

    pub fn claim(&mut self, token: impl Into<String>) -> Option<Lease> {
        let token = token.into();
        let key = self
            .jobs
            .iter()
            .filter(|(_, job)| {
                matches!(
                    job.state,
                    JobState::Submitted | JobState::Queued | JobState::Admitted
                )
            })
            .min_by_key(|(_, job)| {
                (
                    job.request.lane.order(),
                    -job.request.priority,
                    job.request.job_id.clone(),
                )
            })
            .map(|(key, _)| key.clone())?;
        let job = self.jobs.get_mut(&key)?;
        job.state = JobState::Running;
        job.attempts += 1;
        job.token = Some(token.clone());
        job.error = None;
        Some(Lease {
            key,
            token,
            job: job.clone(),
        })
    }

    pub fn stage(
        &mut self,
        lease: &Lease,
        result: impl Into<String>,
        receipt: impl Into<String>,
    ) -> Result<Job, QueueError> {
        let job = self.jobs.get_mut(&lease.key).ok_or(QueueError::Missing)?;
        if job.state == JobState::Published {
            return Err(QueueError::AlreadyPublished);
        }
        if job.state != JobState::Running || job.token.as_deref() != Some(lease.token.as_str()) {
            return Err(QueueError::StaleToken);
        }
        job.state = JobState::Staged;
        job.result = Some(result.into());
        job.receipt = Some(receipt.into());
        Ok(job.clone())
    }

    pub fn publish(&mut self, lease: &Lease) -> Result<Job, QueueError> {
        let job = self.jobs.get_mut(&lease.key).ok_or(QueueError::Missing)?;
        if job.state == JobState::Published {
            return Err(QueueError::AlreadyPublished);
        }
        if job.state != JobState::Staged || job.token.as_deref() != Some(lease.token.as_str()) {
            return Err(QueueError::StaleToken);
        }
        job.state = JobState::Published;
        job.token = None;
        Ok(job.clone())
    }

    pub fn fail(&mut self, lease: &Lease, error: impl Into<String>) -> Result<Job, QueueError> {
        let job = self.jobs.get_mut(&lease.key).ok_or(QueueError::Missing)?;
        if job.token.as_deref() != Some(lease.token.as_str()) {
            return Err(QueueError::StaleToken);
        }
        job.state = JobState::Failed;
        job.token = None;
        job.error = Some(error.into());
        Ok(job.clone())
    }

    pub fn cancel(&mut self, library_id: &str, job_id: &str) -> Result<Job, QueueError> {
        let job = self
            .jobs
            .get_mut(&key(library_id, job_id))
            .ok_or(QueueError::Missing)?;
        if job.state == JobState::Published {
            return Err(QueueError::AlreadyPublished);
        }
        if matches!(job.state, JobState::Cancelled | JobState::Expired) {
            return Ok(job.clone());
        }
        job.state = JobState::Cancelled;
        job.token = None;
        Ok(job.clone())
    }

    pub fn retry(&mut self, library_id: &str, job_id: &str) -> Result<Job, QueueError> {
        let job = self
            .jobs
            .get_mut(&key(library_id, job_id))
            .ok_or(QueueError::Missing)?;
        if !matches!(
            job.state,
            JobState::Failed | JobState::Cancelled | JobState::Reconcile
        ) {
            return Err(QueueError::WrongState);
        }
        job.state = JobState::Queued;
        job.token = None;
        job.error = None;
        Ok(job.clone())
    }

    pub fn reconcile(&mut self, library_id: &str, job_id: &str) -> Result<Job, QueueError> {
        let job = self
            .jobs
            .get_mut(&key(library_id, job_id))
            .ok_or(QueueError::Missing)?;
        if job.state == JobState::Published {
            return Err(QueueError::AlreadyPublished);
        }
        job.state = JobState::Reconcile;
        job.token = None;
        Ok(job.clone())
    }

    pub fn get(&self, library_id: &str, job_id: &str) -> Option<&Job> {
        self.jobs.get(&key(library_id, job_id))
    }

    pub fn pending(&self) -> usize {
        self.jobs
            .values()
            .filter(|job| {
                !matches!(
                    job.state,
                    JobState::Published
                        | JobState::Failed
                        | JobState::Cancelled
                        | JobState::Expired
                )
            })
            .count()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(id: &str, hash: &str, lane: Lane, priority: i32) -> JobRequest {
        JobRequest {
            library_id: "lib-1".into(),
            job_id: id.into(),
            kind: JobKind::SceneRenderFinal,
            lane,
            priority,
            request_hash: hash.into(),
            input_content_ids: vec!["sha256:abc:1".into()],
            scene_graph_hash: Some("scene".into()),
            output_state_hash: Some("output".into()),
            model_program_hash: None,
            compatibility_route: Some("scene-graph".into()),
            delivery_target: Some("hdr2020".into()),
            format: Some("avif10".into()),
            template_id: None,
            batch_id: None,
            target_head: Some("head-1".into()),
        }
    }

    #[test]
    fn idempotent_submission_and_conflict() {
        let mut queue = JobQueue::new();
        assert_eq!(
            queue.submit(request("a", "h1", Lane::SceneFinal, 0)).0,
            SubmitOutcome::Created
        );
        assert_eq!(
            queue.submit(request("a", "h1", Lane::SceneFinal, 0)).0,
            SubmitOutcome::Existing
        );
        assert_eq!(
            queue.submit(request("a", "h2", Lane::SceneFinal, 0)).0,
            SubmitOutcome::Conflict
        );
    }

    #[test]
    fn library_lane_wins() {
        let mut queue = JobQueue::new();
        queue.submit(request("scene", "h1", Lane::SceneFinal, 99));
        queue.submit(request("library", "h2", Lane::Library, 0));
        let lease = queue.claim("token-1").unwrap();
        assert_eq!(lease.job.request.job_id, "library");
    }

    #[test]
    fn publish_once_and_stale_token_rejected() {
        let mut queue = JobQueue::new();
        queue.submit(request("a", "h1", Lane::SceneFinal, 0));
        let lease = queue.claim("token-1").unwrap();
        queue.stage(&lease, "out", "receipt").unwrap();
        queue.publish(&lease).unwrap();
        assert_eq!(queue.publish(&lease), Err(QueueError::AlreadyPublished));
        assert_eq!(
            queue.stage(&lease, "out2", "r2"),
            Err(QueueError::AlreadyPublished)
        );

        queue.submit(request("b", "h2", Lane::SceneFinal, 0));
        let lease = queue.claim("token-2").unwrap();
        let stale = Lease {
            key: lease.key.clone(),
            token: "stale".into(),
            job: lease.job.clone(),
        };
        assert_eq!(
            queue.stage(&stale, "out2", "r2"),
            Err(QueueError::StaleToken)
        );
    }

    #[test]
    fn cancel_then_retry() {
        let mut queue = JobQueue::new();
        queue.submit(request("a", "h1", Lane::SceneFinal, 0));
        queue.cancel("lib-1", "a").unwrap();
        assert_eq!(queue.get("lib-1", "a").unwrap().state, JobState::Cancelled);
        queue.retry("lib-1", "a").unwrap();
        assert_eq!(queue.get("lib-1", "a").unwrap().state, JobState::Queued);
    }

    #[test]
    fn scene_batch_identity_survives() {
        let mut queue = JobQueue::new();
        let mut req = request("batch-item", "h1", Lane::SceneFinal, 0);
        req.batch_id = Some("batch-1".into());
        req.target_head = Some("head-7".into());
        queue.submit(req.clone());
        let job = queue.get("lib-1", "batch-item").unwrap();
        assert_eq!(job.request.batch_id.as_deref(), Some("batch-1"));
        assert_eq!(job.request.target_head.as_deref(), Some("head-7"));
        assert_eq!(
            job.request.compatibility_route.as_deref(),
            Some("scene-graph")
        );
    }
}
