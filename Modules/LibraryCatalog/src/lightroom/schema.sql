CREATE TABLE lc_lr_sources(
    source_id TEXT PRIMARY KEY NOT NULL, locator TEXT NOT NULL UNIQUE, anchor TEXT NOT NULL
);
CREATE TABLE lc_lr_runs(
    run_id TEXT PRIMARY KEY NOT NULL, source_id TEXT NOT NULL REFERENCES lc_lr_sources,
    snapshot_id TEXT NOT NULL REFERENCES lc_resources, preview_id TEXT REFERENCES lc_resources,
    order_id TEXT NOT NULL REFERENCES lc_resources, generation TEXT NOT NULL, source_path TEXT NOT NULL, version TEXT NOT NULL,
    signatures TEXT NOT NULL, dependencies TEXT NOT NULL, sidecars INTEGER NOT NULL,
    phase INTEGER NOT NULL DEFAULT 0, cursor INTEGER NOT NULL DEFAULT -1, pass INTEGER NOT NULL DEFAULT 1,
    state TEXT NOT NULL DEFAULT 'running', started_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(source_id,generation)
);
CREATE TABLE lc_lr_map(
    source_id TEXT NOT NULL REFERENCES lc_lr_sources, kind TEXT NOT NULL, source_key TEXT NOT NULL,
    target_id TEXT NOT NULL, source_revision TEXT NOT NULL, applied_revision INTEGER,
    seen_run TEXT NOT NULL REFERENCES lc_lr_runs,
    PRIMARY KEY(source_id,kind,source_key)
);
CREATE INDEX lc_lr_map_target ON lc_lr_map(target_id);
CREATE TABLE lc_lr_reports(
    run_id TEXT NOT NULL REFERENCES lc_lr_runs, domain TEXT NOT NULL, subject TEXT NOT NULL,
    source_key TEXT NOT NULL, field TEXT NOT NULL, target_id TEXT,
    status TEXT NOT NULL, detail TEXT NOT NULL, evidence TEXT NOT NULL,
    PRIMARY KEY(run_id,domain,subject,source_key,field)
);
CREATE INDEX lc_lr_reports_filter ON lc_lr_reports(run_id,domain,status);
CREATE INDEX lc_lr_reports_domain ON lc_lr_reports(run_id,domain);
CREATE INDEX lc_lr_reports_owner ON lc_lr_reports(run_id,target_id,status);
CREATE TABLE lc_lr_links(
    run_id TEXT NOT NULL REFERENCES lc_lr_runs, kind TEXT NOT NULL, source_key TEXT NOT NULL,
    role TEXT NOT NULL, resource_id TEXT NOT NULL REFERENCES lc_resources, locator TEXT NOT NULL,
    PRIMARY KEY(run_id,kind,source_key,role,resource_id)
);
CREATE TABLE lc_lr_files(
    source_id TEXT NOT NULL REFERENCES lc_lr_sources, file_id TEXT NOT NULL, source_key TEXT NOT NULL,
    folder_id TEXT NOT NULL, source_path TEXT NOT NULL, file_type TEXT NOT NULL, checksum_json TEXT NOT NULL,
    PRIMARY KEY(source_id,file_id)
);
CREATE TABLE lc_lr_looks(
    run_id TEXT NOT NULL REFERENCES lc_lr_runs, work_id TEXT NOT NULL, image_key TEXT NOT NULL,
    cache_uuid TEXT, cache_digest TEXT, develop_digest TEXT, level INTEGER, width INTEGER, height INTEGER,
    candidate INTEGER NOT NULL, decoded INTEGER NOT NULL, revision_bound INTEGER NOT NULL,
    resource_id TEXT REFERENCES lc_resources, state TEXT NOT NULL, manifest TEXT NOT NULL,
    PRIMARY KEY(run_id,work_id)
);
CREATE INDEX lc_lr_looks_work ON lc_lr_looks(work_id,run_id);
CREATE INDEX lc_lr_looks_image ON lc_lr_looks(run_id,image_key);
CREATE TABLE lc_lr_counts(
    run_id TEXT NOT NULL REFERENCES lc_lr_runs,domain TEXT NOT NULL,status TEXT NOT NULL,n INTEGER NOT NULL,
    PRIMARY KEY(run_id,domain,status)
);
CREATE TRIGGER lc_lr_reports_count_insert AFTER INSERT ON lc_lr_reports BEGIN
    INSERT INTO lc_lr_counts(run_id,domain,status,n) VALUES(NEW.run_id,NEW.domain,NEW.status,1)
    ON CONFLICT(run_id,domain,status) DO UPDATE SET n=n+1;
END;
CREATE TRIGGER lc_lr_reports_count_update AFTER UPDATE OF status ON lc_lr_reports WHEN NEW.status!=OLD.status BEGIN
    UPDATE lc_lr_counts SET n=n-1 WHERE run_id=OLD.run_id AND domain=OLD.domain AND status=OLD.status;
    INSERT INTO lc_lr_counts(run_id,domain,status,n) VALUES(NEW.run_id,NEW.domain,NEW.status,1)
    ON CONFLICT(run_id,domain,status) DO UPDATE SET n=n+1;
END;
CREATE TRIGGER lc_lr_reports_count_delete AFTER DELETE ON lc_lr_reports BEGIN
    UPDATE lc_lr_counts SET n=n-1 WHERE run_id=OLD.run_id AND domain=OLD.domain AND status=OLD.status;
END;
CREATE TABLE lc_lr_bindings(
    source_id TEXT NOT NULL REFERENCES lc_lr_sources, source_file_id TEXT NOT NULL,
    library_file_id TEXT NOT NULL REFERENCES lc_files, sha256 TEXT NOT NULL, byte_count INTEGER NOT NULL,
    PRIMARY KEY(source_id,source_file_id)
);
CREATE TABLE lc_lr_file_versions(
    run_id TEXT NOT NULL REFERENCES lc_lr_runs,file_id TEXT NOT NULL,source_path TEXT NOT NULL,checksum_json TEXT NOT NULL,
    PRIMARY KEY(run_id,file_id)
);
