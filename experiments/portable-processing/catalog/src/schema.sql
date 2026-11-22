CREATE TABLE scheduler (
    id INTEGER PRIMARY KEY CHECK (id=1),
    next_slot INTEGER NOT NULL DEFAULT 0 CHECK (next_slot BETWEEN 0 AND 4)
);
INSERT INTO scheduler (id) VALUES (1);

CREATE TABLE jobs (
    id INTEGER PRIMARY KEY,
    job_key TEXT UNIQUE NOT NULL,
    lane TEXT NOT NULL CHECK (lane IN ('editing','library','export')),
    resource TEXT NOT NULL CHECK (resource IN ('cpu','gpu','io')),
    memory_mib INTEGER NOT NULL CHECK (memory_mib BETWEEN 1 AND 512),
    payload TEXT NOT NULL,
    replay_safe INTEGER NOT NULL CHECK (replay_safe IN (0,1)),
    max_attempts INTEGER NOT NULL CHECK (max_attempts BETWEEN 1 AND 8),
    attempt INTEGER NOT NULL DEFAULT 0,
    state TEXT NOT NULL DEFAULT 'queued'
        CHECK (state IN ('queued','running','cancelling','cancelled','failed','done','reconcile','waiting')),
    available_at INTEGER NOT NULL DEFAULT 0,
    token TEXT,
    lease_until INTEGER,
    last_error TEXT,
    result TEXT,
    resource_id TEXT REFERENCES lc_resources(resource_id)
);
CREATE INDEX ready ON jobs(lane, id) WHERE state='queued';
CREATE INDEX active ON jobs(resource, lease_until) WHERE state IN ('running','cancelling');
