CREATE TABLE lc_proc_jobs(
 job_id TEXT PRIMARY KEY NOT NULL,group_id TEXT NOT NULL,revision INTEGER NOT NULL,project_id TEXT NOT NULL,
 operation TEXT NOT NULL CHECK(operation IN ('timelapse','starTrail','hdr','panorama')), recipe_json TEXT NOT NULL, request_hash TEXT NOT NULL,
 parent_job TEXT REFERENCES lc_proc_jobs,state TEXT NOT NULL CHECK(state IN ('queued','preparing','rendering','staged','published','failed','cancelled')),
 attempt INTEGER NOT NULL DEFAULT 0,token TEXT,lease_until INTEGER,receipt_json TEXT,resource_id TEXT REFERENCES lc_resources,
 work_id TEXT,error TEXT,created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
 FOREIGN KEY(group_id,revision) REFERENCES lc_group_versions
);
CREATE INDEX lc_proc_group ON lc_proc_jobs(group_id,revision,created_at);
CREATE UNIQUE INDEX lc_proc_work ON lc_proc_jobs(work_id) WHERE work_id IS NOT NULL;
CREATE TABLE lc_proc_inputs(
 job_id TEXT NOT NULL REFERENCES lc_proc_jobs,capture_id TEXT NOT NULL,file_id TEXT NOT NULL,
 source_position INTEGER NOT NULL,render_position INTEGER,asset_id TEXT,content_id TEXT,sha256 TEXT,byte_count INTEGER,
 work_version TEXT,role TEXT NOT NULL,reason TEXT NOT NULL,source_json TEXT NOT NULL,
 PRIMARY KEY(job_id,file_id),UNIQUE(job_id,render_position)
);
CREATE INDEX lc_proc_files ON lc_proc_inputs(file_id,job_id);
CREATE INDEX lc_proc_captures ON lc_proc_inputs(capture_id,job_id);
CREATE TABLE lc_proc_attempts(
 job_id TEXT NOT NULL REFERENCES lc_proc_jobs,attempt INTEGER NOT NULL,token TEXT NOT NULL,state TEXT NOT NULL,
 diagnostic TEXT,started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,PRIMARY KEY(job_id,attempt)
);
