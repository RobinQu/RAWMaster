CREATE TABLE lc_meta(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
CREATE TABLE lc_changes(seq INTEGER PRIMARY KEY AUTOINCREMENT, asset_id TEXT, domain TEXT NOT NULL);
CREATE TABLE lc_sessions(
  session_id TEXT PRIMARY KEY NOT NULL, project_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('open','sealed')), origin TEXT NOT NULL,
  seal_id TEXT, revision INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE lc_roots(root_id TEXT PRIMARY KEY NOT NULL, volume_id TEXT, relative_root TEXT, local_path TEXT, kind TEXT NOT NULL);
CREATE TABLE lc_pair_dirty(sequence INTEGER PRIMARY KEY AUTOINCREMENT,pair_id TEXT NOT NULL,data TEXT NOT NULL,removed INTEGER NOT NULL);
CREATE TABLE lc_captures(capture_id TEXT PRIMARY KEY NOT NULL);
CREATE TABLE lc_contents(
  content_id TEXT PRIMARY KEY NOT NULL, sha256 TEXT NOT NULL CHECK(length(sha256)=64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
  byte_count INTEGER NOT NULL CHECK(byte_count>=0), UNIQUE(sha256,byte_count)
);
CREATE TABLE lc_files(
  file_id TEXT PRIMARY KEY NOT NULL, capture_id TEXT NOT NULL REFERENCES lc_captures,
  role TEXT NOT NULL CHECK(role IN ('raw','jpeg','other')), pair_locked INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX lc_files_capture ON lc_files(capture_id);
CREATE TABLE lc_asset_files(asset_id TEXT PRIMARY KEY NOT NULL,file_id TEXT NOT NULL REFERENCES lc_files);
CREATE INDEX lc_asset_files_file ON lc_asset_files(file_id);
CREATE TABLE lc_replicas(
  replica_id TEXT PRIMARY KEY NOT NULL, file_id TEXT NOT NULL REFERENCES lc_files, content_id TEXT NOT NULL REFERENCES lc_contents,
  root_id TEXT NOT NULL, relative_path TEXT NOT NULL, path TEXT, kind TEXT NOT NULL CHECK(kind IN ('source','managed','restored')),
  state TEXT NOT NULL CHECK(state IN ('available','missing','changed','unknown')), source_asset_id TEXT
);
CREATE INDEX lc_replicas_content ON lc_replicas(content_id,file_id,state);
CREATE TABLE lc_occurrences(
  session_id TEXT NOT NULL REFERENCES lc_sessions, occurrence_id TEXT NOT NULL, asset_id TEXT NOT NULL, file_id TEXT NOT NULL REFERENCES lc_files,
  root_id TEXT, relative_path TEXT, content_id TEXT REFERENCES lc_contents, disposition TEXT NOT NULL DEFAULT 'pending'
  CHECK(disposition IN ('pending','admitted','sequenceOnly','excluded','failed','reconcile')), explicit_id INTEGER NOT NULL DEFAULT 0, host_snapshot TEXT,
  PRIMARY KEY(session_id,occurrence_id), UNIQUE(session_id,asset_id)
);
CREATE INDEX lc_occurrences_file ON lc_occurrences(file_id,session_id);
CREATE INDEX lc_occurrences_asset ON lc_occurrences(asset_id,session_id);
CREATE TABLE lc_scopes(
  scope_id TEXT PRIMARY KEY NOT NULL, session_id TEXT NOT NULL, occurrence_id TEXT NOT NULL, project_id TEXT NOT NULL,
  asset_id TEXT NOT NULL,file_id TEXT NOT NULL REFERENCES lc_files,content_id TEXT NOT NULL REFERENCES lc_contents,
  kind TEXT NOT NULL CHECK(kind IN ('admitted','sequenceOnly','restored')), operation_id TEXT NOT NULL,
  FOREIGN KEY(session_id,occurrence_id) REFERENCES lc_occurrences(session_id,occurrence_id), UNIQUE(session_id,occurrence_id,project_id)
);
CREATE INDEX lc_scopes_project ON lc_scopes(project_id,file_id,asset_id);
CREATE INDEX lc_scopes_file ON lc_scopes(file_id,project_id,asset_id);
CREATE INDEX lc_scopes_asset ON lc_scopes(asset_id);
CREATE TABLE lc_scope_times(scope_id TEXT PRIMARY KEY NOT NULL REFERENCES lc_scopes ON DELETE CASCADE, admitted_at REAL NOT NULL);
CREATE TRIGGER lc_record_scope_time AFTER INSERT ON lc_scopes BEGIN
  INSERT INTO lc_scope_times(scope_id,admitted_at)
  VALUES(NEW.scope_id,COALESCE((SELECT json_extract(a.data,'$.admittedAt') FROM project_admissions a
      WHERE a.asset_id=NEW.asset_id AND json_extract(a.data,'$.projectID')=NEW.project_id),
      (julianday('now')-2451910.5)*86400));
END;
CREATE TABLE lc_recovery_hosts(asset_id TEXT PRIMARY KEY NOT NULL,host_session_id TEXT NOT NULL UNIQUE,original_asset_id TEXT NOT NULL,file_id TEXT NOT NULL REFERENCES lc_files,content_id TEXT NOT NULL REFERENCES lc_contents,UNIQUE(original_asset_id,file_id,content_id));
CREATE TABLE lc_receipts(command_id TEXT PRIMARY KEY NOT NULL, fingerprint TEXT NOT NULL, request TEXT NOT NULL, result TEXT NOT NULL);
CREATE TABLE lc_reconciliation(domain TEXT NOT NULL,entity_id TEXT NOT NULL,reason TEXT NOT NULL,PRIMARY KEY(domain,entity_id,reason));
CREATE TABLE lc_pair_events(event_id TEXT PRIMARY KEY NOT NULL,raw_file_id TEXT NOT NULL,jpeg_file_id TEXT NOT NULL,
  action TEXT NOT NULL, manual INTEGER NOT NULL, evidence TEXT NOT NULL);
CREATE TABLE lc_capture_aliases(capture_id TEXT PRIMARY KEY NOT NULL REFERENCES lc_captures,canonical_id TEXT NOT NULL REFERENCES lc_captures,operation_id TEXT NOT NULL);
CREATE TABLE lc_group_dirty(group_id TEXT PRIMARY KEY NOT NULL);
CREATE TABLE lc_group_versions(
  group_id TEXT NOT NULL,revision INTEGER NOT NULL,project_id TEXT NOT NULL,kind TEXT NOT NULL,locked INTEGER NOT NULL,
  evidence TEXT NOT NULL,tombstoned INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(group_id,revision)
);
CREATE TABLE lc_group_members(
  group_id TEXT NOT NULL,revision INTEGER NOT NULL,capture_id TEXT NOT NULL REFERENCES lc_captures,position INTEGER NOT NULL,included INTEGER NOT NULL,
  PRIMARY KEY(group_id,revision,capture_id), UNIQUE(group_id,revision,position),FOREIGN KEY(group_id,revision) REFERENCES lc_group_versions
);
CREATE TABLE lc_group_file_members(
  group_id TEXT NOT NULL,revision INTEGER NOT NULL,file_id TEXT NOT NULL REFERENCES lc_files,capture_id TEXT NOT NULL REFERENCES lc_captures,
  position INTEGER NOT NULL,included INTEGER NOT NULL,PRIMARY KEY(group_id,revision,file_id),
  FOREIGN KEY(group_id,revision,capture_id) REFERENCES lc_group_members
);
CREATE INDEX lc_group_files_file ON lc_group_file_members(file_id,group_id,revision);
CREATE INDEX lc_group_members_capture ON lc_group_members(capture_id,group_id,revision);
CREATE VIEW lc_catalog_files(file_id,asset_id,capture_id,project_id) AS
  SELECT s.file_id,MIN(s.asset_id),f.capture_id,s.project_id FROM lc_scopes s
  JOIN assets a ON a.id=s.asset_id JOIN lc_files f ON f.file_id=s.file_id GROUP BY s.project_id,s.file_id;
CREATE VIEW lc_archive_files(file_id,asset_id,project_id,content_id,sha256,byte_count,path,scope_id) AS
  SELECT DISTINCT s.file_id,s.asset_id,s.project_id,s.content_id,c.sha256,c.byte_count,r.path,s.scope_id
  FROM lc_scopes s JOIN assets a ON a.id=s.asset_id JOIN lc_contents c ON c.content_id=s.content_id
  LEFT JOIN lc_replicas r ON r.content_id=c.content_id AND r.file_id=s.file_id AND r.state='available'
    AND (r.source_asset_id IS NULL OR EXISTS(SELECT 1 FROM lc_scopes origin WHERE origin.asset_id=r.source_asset_id AND origin.content_id=r.content_id));
CREATE VIEW lc_asset_input AS
  SELECT a.id AS asset_id, a.session_id, a.source_path AS original_path, json_extract(a.data,'$.relativePath') AS relative_path,
    COALESCE(json_extract(a.data,'$.effectiveSourcePath'),a.source_path) AS source_path,
    COALESCE(json_extract(a.data,'$.effectiveManagedPath'),json_extract(a.data,'$.currentPath'),a.source_path) AS current_path,
    json_extract(s.data,'$.mode') AS mode, json_extract(a.data,'$.availability') AS availability,
    json_extract(a.data,'$.importState') AS import_state, lower(json_extract(a.data,'$.contentHash')) AS sha256,
    json_extract(a.data,'$.fileSize') AS byte_count,
    CASE WHEN json_extract(a.data,'$.importState')='ready' AND json_type(a.data,'$.contentHash')='text'
      AND length(json_extract(a.data,'$.contentHash'))=64 AND lower(json_extract(a.data,'$.contentHash')) NOT GLOB '*[^0-9a-f]*'
      AND json_type(a.data,'$.fileSize')='integer' AND json_extract(a.data,'$.fileSize')>=0
      THEN 'sha256:'||lower(json_extract(a.data,'$.contentHash'))||':'||json_extract(a.data,'$.fileSize') END AS content_id,
    CASE WHEN (lower(json_extract(a.data,'$.filename')) GLOB '*.jpeg' OR lower(json_extract(a.data,'$.filename')) GLOB '*.jpg') THEN 'jpeg'
      WHEN lower(substr(json_extract(a.data,'$.filename'),-4)) IN ('.arw','.dng','.raw','.cr2','.cr3','.nef','.raf','.orf','.rw2','.nrw','.pef','.srw','.rwl') THEN 'raw'
      ELSE 'other' END AS role
  FROM assets a JOIN sessions s ON s.id=a.session_id;
CREATE VIEW lc_touch_asset(asset_id) AS SELECT id FROM assets WHERE 0;
CREATE TRIGGER lc_touch_asset_write INSTEAD OF INSERT ON lc_touch_asset BEGIN
  INSERT OR IGNORE INTO lc_captures SELECT 'capture:'||asset_id FROM lc_asset_input a
    WHERE a.asset_id=NEW.asset_id AND NOT EXISTS(SELECT 1 FROM lc_asset_files WHERE asset_id=a.asset_id);
  INSERT OR IGNORE INTO lc_files(file_id,capture_id,role) SELECT asset_id,'capture:'||asset_id,role FROM lc_asset_input a
    WHERE a.asset_id=NEW.asset_id AND NOT EXISTS(SELECT 1 FROM lc_asset_files WHERE asset_id=a.asset_id);
  INSERT OR IGNORE INTO lc_asset_files SELECT asset_id,asset_id FROM lc_asset_input WHERE asset_id=NEW.asset_id;
  INSERT OR IGNORE INTO lc_contents SELECT content_id,sha256,byte_count FROM lc_asset_input WHERE asset_id=NEW.asset_id AND content_id IS NOT NULL;
  INSERT OR IGNORE INTO lc_occurrences(session_id,occurrence_id,asset_id,file_id,root_id,relative_path,content_id,host_snapshot)
    SELECT a.session_id,a.asset_id,a.asset_id,f.file_id,'source:'||a.session_id,a.relative_path,a.content_id,(SELECT data FROM assets WHERE id=a.asset_id)
    FROM lc_asset_input a JOIN lc_asset_files f USING(asset_id) JOIN lc_sessions s ON s.session_id=a.session_id
    WHERE a.asset_id=NEW.asset_id AND s.state='open' AND s.origin!='version-host';
  UPDATE lc_occurrences SET content_id=(SELECT content_id FROM lc_asset_input WHERE asset_id=NEW.asset_id),host_snapshot=(SELECT data FROM assets WHERE id=NEW.asset_id)
    WHERE asset_id=NEW.asset_id AND disposition='pending' AND session_id IN(SELECT session_id FROM lc_sessions WHERE state='open');
  UPDATE lc_replicas SET state='unknown' WHERE replica_id IN ('v7-source:'||NEW.asset_id,'v7-managed:'||NEW.asset_id);
  INSERT INTO lc_replicas(replica_id,file_id,content_id,root_id,relative_path,path,kind,state,source_asset_id)
    SELECT 'v7-source:'||a.asset_id,f.file_id,a.content_id,'source:'||a.session_id,COALESCE(a.relative_path,''),a.source_path,'source',
      CASE WHEN a.mode='copy' THEN 'available' WHEN a.availability IN ('available','missing','changed') THEN a.availability ELSE 'unknown' END,a.asset_id
    FROM lc_asset_input a JOIN lc_asset_files f USING(asset_id) WHERE a.asset_id=NEW.asset_id AND a.content_id IS NOT NULL AND a.source_path IS NOT NULL
    ON CONFLICT(replica_id) DO UPDATE SET file_id=excluded.file_id,content_id=excluded.content_id,path=excluded.path,relative_path=excluded.relative_path,state=excluded.state;
  INSERT INTO lc_replicas(replica_id,file_id,content_id,root_id,relative_path,path,kind,state,source_asset_id)
    SELECT 'v7-managed:'||a.asset_id,f.file_id,a.content_id,'managed:'||a.session_id,COALESCE(a.relative_path,''),a.current_path,'managed',
      CASE WHEN a.availability IN ('available','missing','changed') THEN a.availability ELSE 'unknown' END,a.asset_id
    FROM lc_asset_input a JOIN lc_asset_files f USING(asset_id) WHERE a.asset_id=NEW.asset_id AND a.mode='copy' AND a.content_id IS NOT NULL AND a.current_path IS NOT NULL
    AND (NOT EXISTS(SELECT 1 FROM lc_replicas restored WHERE restored.file_id=f.file_id AND restored.content_id=a.content_id AND restored.path=a.current_path AND restored.kind='restored') OR EXISTS(SELECT 1 FROM lc_replicas managed WHERE managed.replica_id='v7-managed:'||a.asset_id AND managed.path=a.current_path))
    ON CONFLICT(replica_id) DO UPDATE SET file_id=excluded.file_id,content_id=excluded.content_id,path=excluded.path,relative_path=excluded.relative_path,state=excluded.state;
END;
CREATE TRIGGER lc_sync_session_insert AFTER INSERT ON sessions BEGIN
  INSERT OR IGNORE INTO lc_sessions(session_id,project_id,state,origin) VALUES(NEW.id,json_extract(NEW.data,'$.projectID'),'open','host');
  INSERT INTO lc_roots VALUES('source:'||NEW.id,NULL,NULL,COALESCE(json_extract(NEW.data,'$.effectiveSourceRoot'),json_extract(NEW.data,'$.sourcePath')),'source') ON CONFLICT(root_id) DO NOTHING;
  INSERT INTO lc_roots SELECT 'managed:'||NEW.id,NULL,NULL,COALESCE(json_extract(NEW.data,'$.effectiveManagedRoot'),json_extract(NEW.data,'$.destinationPath')),'managed' WHERE json_extract(NEW.data,'$.mode')='copy' ON CONFLICT(root_id) DO NOTHING;
END;
CREATE TRIGGER lc_sync_asset_insert AFTER INSERT ON assets BEGIN INSERT INTO lc_touch_asset VALUES(NEW.id); END;
CREATE TRIGGER lc_sync_asset_update AFTER UPDATE ON assets WHEN
  json_extract(OLD.data,'$.fileSize','$.contentHash','$.availability','$.importState','$.effectiveSourcePath','$.currentPath','$.effectiveManagedPath','$.relativePath')
  IS NOT json_extract(NEW.data,'$.fileSize','$.contentHash','$.availability','$.importState','$.effectiveSourcePath','$.currentPath','$.effectiveManagedPath','$.relativePath')
  BEGIN INSERT INTO lc_touch_asset VALUES(NEW.id); END;
CREATE TRIGGER lc_guard_asset_insert BEFORE INSERT ON assets
  WHEN EXISTS(SELECT 1 FROM lc_sessions WHERE session_id=NEW.session_id AND state='sealed')
  BEGIN SELECT RAISE(ABORT,'sealed import requires a new session'); END;
CREATE TRIGGER lc_guard_asset_identity BEFORE UPDATE ON assets WHEN NEW.id!=OLD.id OR NEW.session_id!=OLD.session_id
  BEGIN SELECT RAISE(ABORT,'immutable source identity'); END;
CREATE TRIGGER lc_guard_workflow_reopen BEFORE UPDATE ON session_workflows
  WHEN EXISTS(SELECT 1 FROM lc_sessions WHERE session_id=NEW.id AND state='sealed')
  AND json_extract(NEW.data,'$.phase') NOT IN ('closed','legacyHistory') BEGIN SELECT RAISE(ABORT,'sealed import requires a new session'); END;
CREATE TRIGGER lc_dirty_pair_insert AFTER INSERT ON capture_pairs BEGIN
  INSERT INTO lc_pair_dirty(pair_id,data,removed) VALUES(NEW.id,NEW.data,0); END;
CREATE TRIGGER lc_dirty_pair_update AFTER UPDATE ON capture_pairs WHEN NEW.data IS NOT OLD.data BEGIN
  INSERT INTO lc_pair_dirty(pair_id,data,removed) VALUES(OLD.id,OLD.data,1);
  INSERT INTO lc_pair_dirty(pair_id,data,removed) VALUES(NEW.id,NEW.data,0); END;
CREATE TRIGGER lc_dirty_pair_delete AFTER DELETE ON capture_pairs BEGIN
  INSERT INTO lc_pair_dirty(pair_id,data,removed) VALUES(OLD.id,OLD.data,1); END;
CREATE TRIGGER lc_guard_session_reopen BEFORE UPDATE ON lc_sessions WHEN OLD.state='sealed'
  BEGIN SELECT RAISE(ABORT,'a sealed session is immutable'); END;
CREATE TRIGGER lc_guard_session_delete BEFORE DELETE ON lc_sessions WHEN OLD.state='sealed'
  BEGIN SELECT RAISE(ABORT,'a sealed session is immutable'); END;
CREATE TRIGGER lc_guard_occ_insert BEFORE INSERT ON lc_occurrences
  WHEN EXISTS(SELECT 1 FROM lc_sessions WHERE session_id=NEW.session_id AND state='sealed')
  BEGIN SELECT RAISE(ABORT,'a sealed occurrence is immutable'); END;
CREATE TRIGGER lc_guard_occ_update BEFORE UPDATE ON lc_occurrences
  WHEN EXISTS(SELECT 1 FROM lc_sessions WHERE session_id=OLD.session_id AND state='sealed')
  BEGIN SELECT RAISE(ABORT,'a sealed occurrence is immutable'); END;
CREATE TRIGGER lc_guard_occ_delete BEFORE DELETE ON lc_occurrences
  WHEN EXISTS(SELECT 1 FROM lc_sessions WHERE session_id=OLD.session_id AND state='sealed')
  BEGIN SELECT RAISE(ABORT,'a sealed occurrence is immutable'); END;
CREATE TRIGGER lc_occ_revision_insert AFTER INSERT ON lc_occurrences BEGIN
  UPDATE lc_sessions SET revision=revision+1 WHERE session_id=NEW.session_id AND state='open'; END;
CREATE TRIGGER lc_occ_revision_update AFTER UPDATE ON lc_occurrences
  WHEN NEW.content_id IS NOT OLD.content_id OR NEW.file_id!=OLD.file_id OR NEW.occurrence_id!=OLD.occurrence_id BEGIN
  UPDATE lc_sessions SET revision=revision+1 WHERE session_id=NEW.session_id AND state='open'; END;
CREATE TRIGGER lc_occ_revision_delete AFTER DELETE ON lc_occurrences BEGIN
  UPDATE lc_sessions SET revision=revision+1 WHERE session_id=OLD.session_id AND state='open'; END;
