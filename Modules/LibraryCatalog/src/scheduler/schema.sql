CREATE TABLE lc_task_scheduler (
    id INTEGER PRIMARY KEY CHECK (id=1),
    cpu_slots INTEGER NOT NULL DEFAULT 4 CHECK(cpu_slots BETWEEN 1 AND 256),
    gpu_slots INTEGER NOT NULL DEFAULT 1 CHECK(gpu_slots BETWEEN 0 AND 32),
    io_slots INTEGER NOT NULL DEFAULT 3 CHECK(io_slots BETWEEN 1 AND 256),
    memory_mib INTEGER NOT NULL DEFAULT 4096 CHECK(memory_mib BETWEEN 1 AND 32768),
    next_slot INTEGER NOT NULL DEFAULT 0 CHECK (next_slot BETWEEN 0 AND 4)
);
INSERT INTO lc_task_scheduler (id) VALUES (1);

CREATE TABLE lc_task_jobs (
    id INTEGER PRIMARY KEY,
    job_key TEXT UNIQUE NOT NULL,
    lane TEXT NOT NULL CHECK (lane IN ('editing','library','export')),
    resource TEXT NOT NULL CHECK (resource IN ('cpu','gpu','io')),
    memory_mib INTEGER NOT NULL CHECK (memory_mib BETWEEN 1 AND 32768),
    payload TEXT NOT NULL,
    replay_safe INTEGER NOT NULL CHECK (replay_safe IN (0,1)),
    max_attempts INTEGER NOT NULL CHECK (max_attempts BETWEEN 1 AND 8),
    attempt INTEGER NOT NULL DEFAULT 0,
    state TEXT NOT NULL DEFAULT 'queued'
        CHECK (state IN ('queued','running','cancelling','cancelled','failed','done','reconcile','waiting')),
    available_at INTEGER NOT NULL DEFAULT 0,
    claim_interest_until INTEGER NOT NULL DEFAULT 0,
    submission_token TEXT,
    token TEXT,
    lease_until INTEGER,
    last_error TEXT,
    result TEXT,
    resource_id TEXT REFERENCES lc_resources(resource_id),
    prepared_stage TEXT,
    prepared_destination TEXT,
    prepared_sha256 TEXT,
    prepared_bytes INTEGER,
    prepared_file_identity TEXT,
    prepared_detached INTEGER NOT NULL DEFAULT 0 CHECK(prepared_detached IN (0,1) AND (prepared_detached=0 OR prepared_stage IS NOT NULL)),
    final_verified INTEGER NOT NULL DEFAULT 0 CHECK(final_verified IN (0,1) AND (final_verified=0 OR prepared_stage IS NOT NULL)),
    CHECK ((prepared_stage IS NULL AND prepared_destination IS NULL AND prepared_sha256 IS NULL AND prepared_bytes IS NULL AND prepared_file_identity IS NULL)
        OR (prepared_stage IS NOT NULL AND prepared_destination IS NOT NULL AND prepared_sha256 IS NOT NULL AND prepared_bytes IS NOT NULL AND length(prepared_sha256)=64 AND prepared_bytes>0))
);
CREATE INDEX lc_task_ready ON lc_task_jobs(lane, id) WHERE state='queued';
CREATE INDEX lc_task_external_pending ON lc_task_jobs(lane,job_key)
    WHERE prepared_stage IS NOT NULL AND prepared_detached=0 AND state!='done';
CREATE INDEX lc_task_active ON lc_task_jobs(resource, lease_until) WHERE state IN ('running','cancelling');

CREATE TABLE lc_task_attempts(
    job_id INTEGER NOT NULL REFERENCES lc_task_jobs(id), attempt INTEGER NOT NULL,
    token TEXT NOT NULL UNIQUE, state TEXT NOT NULL, started_at INTEGER NOT NULL,
    finished_at INTEGER, error TEXT, PRIMARY KEY(job_id,attempt)
);
CREATE TRIGGER lc_task_started AFTER UPDATE OF attempt ON lc_task_jobs
WHEN NEW.attempt > OLD.attempt BEGIN
    INSERT INTO lc_task_attempts(job_id,attempt,token,state,started_at)
    VALUES(NEW.id,NEW.attempt,NEW.token,'running',unixepoch());
END;
CREATE TRIGGER lc_task_ended AFTER UPDATE OF state ON lc_task_jobs
WHEN OLD.state IN ('running','cancelling') AND NEW.state NOT IN ('running','cancelling') BEGIN
    UPDATE lc_task_attempts SET state=NEW.state, finished_at=unixepoch(), error=NEW.last_error
    WHERE job_id=OLD.id AND attempt=OLD.attempt;
END;
